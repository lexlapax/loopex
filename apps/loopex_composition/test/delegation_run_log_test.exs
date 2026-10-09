Code.require_file("support/delegation_parent_binding_fixture.exs", __DIR__)

defmodule LoopexComposition.DelegationRunLogTest do
  use ExUnit.Case, async: false

  alias Loopex.{Runtime, Store}
  alias Loopex.Store.{Local, Memory}
  alias LoopexComposition.Delegation.{ParentBinding, RetainedObjects, RunMutation}
  alias LoopexComposition.DelegationParentBindingFixture, as: Fixture
  alias LoopexComposition.Placement

  @limits_json ~s({"child_bounds":{"deadline_ms":600000,"max_turns":4,"token_budget":8192},"enabled":true,"kind":"declaration","max_children":2,"max_tokens":1024,"role_budgets":[{"context_token_budget":8192,"role":"inspect","system_class_tokens":5000}],"roles":["inspect"],"token_budget":32768,"version":1})

  setup do
    root =
      Path.join(physical_tmp(), "loopex-run-log-#{Base.encode16(:crypto.strong_rand_bytes(12))}")

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

  for adapter <- [Memory, Local] do
    @adapter adapter
    test "#{inspect(adapter)} physical initialization has independent bytes and reopens without activation",
         context do
      context = bound(context, [], @adapter)
      before = store_image(context)
      tx = initialize(context)
      {header, encoded_tx, result} = authored_bytes(context)
      assert Fixture.json(tx) == encoded_tx

      assert {:ok, key} =
               RetainedObjects.open_run(context.owner, "create", context.ids, context.runtime)

      assert key == run_key(context.ids)
      target = path(context)
      assert File.read!(target) == header
      assert Bitwise.band(File.stat!(Path.dirname(target)).mode, 0o7777) == 0o700
      assert Bitwise.band(File.stat!(target).mode, 0o7777) == 0o600
      assert {:ok, ^result} = commit(context, tx)
      bytes = header <> framed(encoded_tx)
      assert File.read!(target) == bytes
      assert {:ok, state} = read(context)

      assert Map.take(state, [
               :version,
               :credit,
               :phase,
               :count,
               :reserved_tokens,
               :charged_tokens
             ]) ==
               %{
                 version: 1,
                 credit: 0,
                 phase: :initialized,
                 count: 0,
                 reserved_tokens: 0,
                 charged_tokens: 0
               }

      assert state.bytes == byte_size(bytes)
      assert state.transactions == [{tx, result}]
      assert {:ok, ^result} = commit(context, tx)
      assert File.read!(target) == bytes
      stop_join(context.owner)
      reopened = open(context)
      context = %{context | owner: reopened}
      assert read(context) == {:error, :ledger_fenced}
      assert RetainedObjects.install(reopened, "{}") == {:error, :ledger_fenced}
      classify_binding(context)
      assert RetainedObjects.install(reopened, "{}") == {:error, :ledger_fenced}
      assert {:ok, ^result} = lookup(context, tx["tx_id"])
      assert {:ok, ^state} = read(context)
      assert {:ok, ^result} = commit(context, tx)
      assert File.read!(target) == bytes
      assert store_image(context) == before
      assert {:ok, %{sessions: sessions}} = Runtime.children(context.runtime)
      assert DynamicSupervisor.which_children(sessions) == []
    end
  end

  test "unbound or unavailable actual parent history cannot initialize a run", context do
    context = bound(context)
    assert {:error, _} = RetainedObjects.open_run(context.owner, "create", context.ids, nil)
    refute File.exists?(Path.join(context.directory, "runs"))
    capture = Fixture.capture_for("unbound")
    assert {:ok, _} = RetainedObjects.open_binding(context.owner, "unbound", capture.object_bytes)
    assert {:ok, _} = RetainedObjects.commit_binding(context.owner, "unbound", prepare(capture))

    assert {:error, _} =
             RetainedObjects.open_run(context.owner, "unbound", context.ids, context.runtime)

    refute File.exists?(Path.join(context.directory, "runs"))
  end

  test "wrong runtime parent and opaque run scope refuse without a physical run", context do
    context = bound(context)

    for ids <- [
          ["other", context.session, "run"],
          ["runtime", "other", "run"],
          ["runtime", context.session, ""],
          ["runtime", context.session, self()],
          []
        ] do
      assert {:error, _} = RetainedObjects.open_run(context.owner, "create", ids, context.runtime)
    end

    refute File.exists?(Path.join(context.directory, "runs"))
    ids = ["runtime", context.session, <<255, 0, 128>>]
    assert {:ok, _} = RetainedObjects.open_run(context.owner, "create", ids, context.runtime)
    context = %{context | ids: ids}
    assert {:ok, _} = commit(context, initialize(context))
    assert {:ok, %{phase: :initialized}} = read(context)
  end

  test "changed and stale initialization cannot append or reset the original projection",
       context do
    context = initialized(context)
    tx = initialize(context)
    before = File.read!(path(context))
    changed = put_in(tx["mutation"], ["limits", "token_budget"], 1)
    assert {:ok, changed} = RunMutation.transaction(context.ids, 0, changed)
    assert changed["tx_id"] == tx["tx_id"]
    assert commit(context, changed) == {:error, :run_transaction_conflict}
    assert {:ok, stale} = RunMutation.transaction(context.ids, 1, tx["mutation"])
    assert commit(context, stale) == {:error, :run_transaction_conflict}

    assert {:ok, _} =
             RetainedObjects.open_run(context.owner, "create", context.ids, context.runtime)

    assert File.read!(path(context)) == before
    assert {:ok, %{count: 0, reserved_tokens: 0, charged_tokens: 0}} = read(context)
  end

  test "a missing required run cannot become an empty run", context do
    context = initialized(context)
    File.rm!(path(context))

    assert RetainedObjects.open_run(context.owner, "create", context.ids, context.runtime) ==
             {:error, :run_unavailable}

    assert lookup(context, initialize(context)["tx_id"]) == {:error, :run_unavailable}
    refute File.exists?(path(context))
    assert RetainedObjects.install(context.owner, "{}") == {:error, :ledger_fenced}
  end

  test "the original retained declaration is revalidated before run IO", context do
    context = bound(context)

    File.write!(
      Path.join(context.directory, context.capture.creation["declaration_sha256"]),
      "{}"
    )

    assert {:error, _} =
             RetainedObjects.open_run(context.owner, "create", context.ids, context.runtime)

    refute File.exists?(Path.join(context.directory, "runs"))
    assert RetainedObjects.install(context.owner, "{}") == {:error, :ledger_fenced}
  end

  test "physical prefix rejects duplicate appended initialization and unsupported later transactions",
       context do
    context = initialized(context)
    before = File.read!(path(context))
    tx = initialize(context)

    assert RetainedObjects.decode_run(before <> framed(Fixture.json(tx)), context.ids) ==
             {:error, :invalid_run_log}

    mutation = %{
      "kind" => "child_created",
      "operation_identity" => %{
        "parent_session_id" => Base.encode64(context.session),
        "parent_run_id" => Base.encode64("run"),
        "operation_id" => Base.encode64("operation")
      },
      "child_session_id" => Base.encode64("child"),
      "child_creation_sha256" => String.duplicate("a", 64),
      "configuration_digest" => String.duplicate("b", 64),
      "tool_selection_sha256" => String.duplicate("c", 64),
      "policy_defer_mode" => "refuse"
    }

    assert {:ok, unsupported} = RunMutation.transaction(context.ids, 1, mutation)
    assert commit(context, unsupported) == {:error, :invalid_run_prefix}
    {header, _json, _result} = authored_bytes(context)

    assert RetainedObjects.decode_run(header <> framed(Fixture.json(unsupported)), context.ids) ==
             {:error, :invalid_run_log}

    assert File.read!(path(context)) == before
    File.write!(path(context), before <> framed(Fixture.json(tx)))
    assert read(context) == {:error, :invalid_run_log}
    assert RetainedObjects.install(context.owner, "{}") == {:error, :ledger_fenced}
  end

  test "complete header payload and checksum corruption never become repairable tails", context do
    context = initialized(context)
    bytes = File.read!(path(context))
    {header, _tx, _result} = authored_bytes(context)

    for offset <- [
          0,
          8,
          13,
          14,
          byte_size(header) - 1,
          byte_size(header) + 46,
          byte_size(bytes) - 1
        ] do
      damaged = flip(bytes, offset)
      assert RetainedObjects.decode_run(damaged, context.ids) == {:error, :invalid_run_log}
    end

    assert RetainedObjects.decode_run(header <> bad_length(65_537), context.ids) ==
             {:error, :invalid_run_log}

    for length <- [0, 1, 9, 13, 45, byte_size(header) - 1] do
      assert RetainedObjects.decode_run(binary_part(header, 0, length), context.ids) ==
               {:error, :invalid_run_log}
    end

    File.write!(path(context), flip(bytes, byte_size(bytes) - 1))
    assert read(context) == {:error, :invalid_run_log}
    stop_join(context.owner)
    context = %{context | owner: open(context, recover_stale_writer: true)}
    classify_binding(context)
    assert lookup(context, initialize(context)["tx_id"]) == {:error, :invalid_run_log}
    assert File.read!(path(context)) == flip(bytes, byte_size(bytes) - 1)
  end

  test "synthetic partial tails lack stale-writer repair permission", context do
    context = bound(context)

    assert {:ok, _} =
             RetainedObjects.open_run(context.owner, "create", context.ids, context.runtime)

    tx = initialize(context)
    header = File.read!(path(context))
    encoded = framed(Fixture.json(tx))
    stop_join(context.owner)
    File.write!(path(context), header <> binary_part(encoded, 0, div(byte_size(encoded), 2)))
    context = %{context | owner: open(context, recover_stale_writer: true)}
    classify_binding(context)
    before = File.read!(path(context))
    assert lookup(context, tx["tx_id"]) == {:error, :run_recovery_unproved}
    assert File.read!(path(context)) == before
    assert RetainedObjects.install(context.owner, "{}") == {:error, :ledger_fenced}
  end

  test "raw run cap plus one refuses without reducing or rewriting the file", context do
    context = initialized(context)
    bytes = :binary.copy(<<0>>, 16_777_217)
    File.write!(path(context), bytes)
    assert RetainedObjects.decode_run(bytes, context.ids) == {:error, :invalid_run_log}
    assert read(context) == {:error, :run_unavailable}
    assert File.stat!(path(context)).size == 16_777_217
    assert RetainedObjects.install(context.owner, "{}") == {:error, :ledger_fenced}
  end

  test "a complete run prefix cannot be rebound to another run identity", context do
    context = initialized(context)
    bytes = File.read!(path(context))

    for ids <- [
          ["other", context.session, "run"],
          ["runtime", "other", "run"],
          ["runtime", context.session, "other-run"]
        ] do
      assert RetainedObjects.decode_run(bytes, ids) == {:error, :invalid_run_log}
    end

    assert File.read!(path(context)) == bytes
  end

  for cut <- [
        :run_header_written,
        :run_header_synced,
        :run_partial_written,
        :run_written,
        :run_synced,
        :run_closed,
        :run_directory_synced
      ] do
    test "actual run IO error at #{cut} retains exact original transaction uncertainty",
         context do
      cut = unquote(cut)
      armed = :atomics.new(1, [])
      context = bound(context, checkpoint: error_checkpoint(armed, cut))
      tx = initialize(context)
      result = fault_run_io(context, tx, cut, armed)

      assert result == {:error, {:commit_unknown, tx["tx_id"]}}
      assert RetainedObjects.install(context.owner, "{}") == {:error, :ledger_fenced}

      assert RetainedObjects.open_binding(
               context.owner,
               "other",
               Fixture.capture_for("other").object_bytes
             ) ==
               {:error, :ledger_fenced}

      assert RetainedObjects.commit_binding(
               context.owner,
               "create",
               context.bind,
               context.runtime
             ) ==
               {:error, :ledger_fenced}

      assert RetainedObjects.lookup_binding(
               context.owner,
               "create",
               context.bind["tx_id"],
               context.runtime
             ) ==
               {:error, :ledger_fenced}

      assert lookup(context, String.duplicate("0", 64)) == {:error, :ledger_fenced}

      assert_io_error_recovery(context, tx, cut)
    end
  end

  test "binding uncertainty excludes run initialization and cannot be cleared through run lookup",
       context do
    armed = :atomics.new(1, [])
    context = bound(context, checkpoint: error_checkpoint(armed, :binding_written))

    assert {:ok, _} =
             RetainedObjects.open_run(context.owner, "create", context.ids, context.runtime)

    other = Fixture.capture_for("other")
    assert {:ok, _} = RetainedObjects.open_binding(context.owner, "other", other.object_bytes)
    tx = prepare(other)
    :atomics.put(armed, 1, 1)

    assert {:error, {:commit_unknown, _}} =
             RetainedObjects.commit_binding(context.owner, "other", tx)

    before = File.read!(path(context))
    assert commit(context, initialize(context)) == {:error, :ledger_fenced}
    assert lookup(context, initialize(context)["tx_id"]) == {:error, :ledger_fenced}
    assert RetainedObjects.install(context.owner, "{}") == {:error, :ledger_fenced}
    assert File.read!(path(context)) == before
    assert {:ok, _} = RetainedObjects.lookup_binding(context.owner, "other", tx["tx_id"])
    assert {:ok, _} = commit(context, initialize(context))
  end

  test "every present run and binding must be classified before mutations resume", context do
    context = initialized(context)
    other_ids = ["runtime", context.session, "other-run"]

    assert {:ok, _} =
             RetainedObjects.open_run(context.owner, "create", other_ids, context.runtime)

    other = %{context | ids: other_ids}
    assert {:ok, _} = commit(other, initialize(other))
    stop_join(context.owner)
    context = %{context | owner: open(context)}
    other = %{other | owner: context.owner}
    classify_binding(context)
    assert {:ok, _} = lookup(context, initialize(context)["tx_id"])
    assert RetainedObjects.install(context.owner, "{}") == {:error, :ledger_fenced}
    assert commit(context, initialize(context)) == {:error, :ledger_fenced}
    assert {:ok, _} = lookup(other, initialize(other)["tx_id"])
    assert {:ok, _} = commit(context, initialize(context))
    assert {:ok, _} = RetainedObjects.install(context.owner, "{}")
  end

  for cut <- [
        :run_header_synced,
        :run_partial_written,
        :run_written,
        :run_synced,
        :run_before_truncate,
        :run_truncated,
        :run_repair_synced
      ] do
    test "actual writer death at #{cut} joins original actors before exclusive run recovery",
         context do
      writer_death(context, unquote(cut))
    end
  end

  for cut <- [:run_before_truncate, :run_truncated, :run_repair_synced] do
    test "actual run repair error at #{cut} preserves recovery exclusion", context do
      context = partial_run(context)
      stop_join(context.owner)
      armed = :atomics.new(1, [])

      context = %{
        context
        | owner:
            open(context,
              recover_stale_writer: true,
              checkpoint: error_checkpoint(armed, unquote(cut))
            )
      }

      classify_binding(context)
      :atomics.put(armed, 1, 1)
      tx = initialize(context)
      assert {:error, _} = lookup(context, tx["tx_id"])
      assert RetainedObjects.install(context.owner, "{}") == {:error, :ledger_fenced}
      stop_join(context.owner)
      context = %{context | owner: open(context, recover_stale_writer: true)}
      classify_binding(context)
      assert lookup(context, tx["tx_id"]) == {:ok, :absent}
      {header, _json, _result} = authored_bytes(context)
      assert File.read!(path(context)) == header
    end
  end

  test "a recovered acquisition cannot repair its own newly interrupted append", context do
    context = partial_run(context)
    stop_join(context.owner)
    armed = :atomics.new(1, [])

    context = %{
      context
      | owner:
          open(context,
            recover_stale_writer: true,
            checkpoint: error_checkpoint(armed, :run_partial_written)
          )
    }

    classify_binding(context)
    tx = initialize(context)
    assert lookup(context, tx["tx_id"]) == {:ok, :absent}
    :atomics.put(armed, 1, 1)
    assert {:error, {:commit_unknown, _}} = commit(context, tx)
    assert lookup(context, tx["tx_id"]) == {:error, :run_recovery_unproved}
  end

  test "repair rechecks the exact run image after its real pre-truncate checkpoint", context do
    context = partial_run(context)
    stop_join(context.owner)
    target = path(context)
    before = File.read!(target)

    context = %{
      context
      | owner:
          open(context,
            recover_stale_writer: true,
            checkpoint: fn step ->
              if step == :run_before_truncate, do: File.write!(target, "changed", [:append])
              :ok
            end
          )
    }

    classify_binding(context)
    assert {:error, _} = lookup(context, initialize(context)["tx_id"])
    assert File.read!(target) == before <> "changed"
    assert RetainedObjects.install(context.owner, "{}") == {:error, :ledger_fenced}
  end

  test "duplicate confirmation sync uncertainty retains the original result behind the shared fence",
       context do
    armed = :atomics.new(1, [])
    context = bound(context, checkpoint: error_checkpoint(armed, :run_recovered_synced))

    assert {:ok, _} =
             RetainedObjects.open_run(context.owner, "create", context.ids, context.runtime)

    tx = initialize(context)
    assert {:ok, original} = commit(context, tx)
    before = File.read!(path(context))
    :atomics.put(armed, 1, 1)
    assert commit(context, tx) == {:error, {:commit_unknown, tx["tx_id"]}}

    assert RetainedObjects.commit_binding(context.owner, "create", context.bind, context.runtime) ==
             {:error, :ledger_fenced}

    assert {:ok, ^original} = lookup(context, tx["tx_id"])
    assert File.read!(path(context)) == before
  end

  test "run path replacement and namespace symlinks refuse physical authority", context do
    context = initialized(context)
    target = path(context)
    bytes = File.read!(target)
    saved = target <> ".saved"
    File.rename!(target, saved)
    File.ln_s!(saved, target)
    assert {:error, _} = read(context)
    File.rm!(target)
    File.ln!(saved, target)
    assert {:error, _} = lookup(context, initialize(context)["tx_id"])
    File.rm!(target)
    File.write!(target, bytes)
    File.chmod!(target, 0o600)
    stop_join(context.owner)
    File.rm!(saved)
    runs = Path.dirname(target)
    File.rename!(runs, runs <> "-old")
    File.ln_s!(runs <> "-old", runs)

    assert {:error, _} =
             RetainedObjects.open(context.root, "runtime", context.lease,
               recover_stale_writer: true
             )
  end

  test "replacement after a physical append returns unknown and rejects the successor", context do
    armed = :atomics.new(1, [])
    parent = self()

    context =
      bound(context,
        checkpoint: fn step ->
          if step == :run_written and :atomics.compare_exchange(armed, 1, 1, 0) == :ok do
            send(parent, {:replace, self()})
            receive do: (:continue -> :ok)
          else
            :ok
          end
        end
      )

    assert {:ok, _} =
             RetainedObjects.open_run(context.owner, "create", context.ids, context.runtime)

    tx = initialize(context)
    owner = context.owner
    Process.unlink(owner)
    monitor = Process.monitor(owner)
    joins = :atomics.new(2, [])
    deadline = System.monotonic_time(:millisecond) + 5_000

    {caller, caller_monitor} =
      spawn_monitor(fn ->
        receive do: (:start_fault -> :ok)
        send(parent, {:ended, commit(context, tx)})
      end)

    :atomics.put(context.cleanup_guard, 1, 0)

    try do
      :atomics.put(armed, 1, 1)
      send(caller, :start_fault)
      assert_receive {:replace, ^owner}, remaining(deadline)
      File.rename!(path(context), path(context) <> ".original")
      {header, _json, _result} = authored_bytes(context)
      File.write!(path(context), header)
      File.chmod!(path(context), 0o600)
      send(owner, :continue)
      assert_receive {:ended, {:error, {:commit_unknown, _}}}, remaining(deadline)
      assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, remaining(deadline)
      :atomics.put(joins, 2, 1)
      assert lookup(context, tx["tx_id"]) == {:error, :binding_file_changed}
    after
      join_fault_actors(
        context,
        [{owner, monitor, 1}, {caller, caller_monitor, 2}],
        joins,
        deadline
      )
    end
  end

  defp writer_death(context, cut) do
    repair_cut = cut in [:run_before_truncate, :run_truncated, :run_repair_synced]
    parent = self()
    armed = :atomics.new(1, [])

    checkpoint = fn step ->
      if step == cut and :atomics.get(armed, 1) == 1 do
        send(parent, {:paused, self()})
        receive do: (:continue -> :ok)
      else
        :ok
      end
    end

    context =
      if repair_cut do
        context = partial_run(context)
        stop_join(context.owner)

        context = %{
          context
          | owner: open(context, recover_stale_writer: true, checkpoint: checkpoint)
        }

        classify_binding(context)
        context
      else
        bound(context, checkpoint: checkpoint)
      end

    header_cut = cut == :run_header_synced

    unless repair_cut or header_cut,
      do:
        assert(
          {:ok, _} =
            RetainedObjects.open_run(context.owner, "create", context.ids, context.runtime)
        )

    tx = initialize(context)
    owner = context.owner
    Process.unlink(owner)
    monitor = Process.monitor(owner)
    joins = :atomics.new(2, [])
    deadline = System.monotonic_time(:millisecond) + 5_000

    {caller, caller_monitor} =
      spawn_monitor(fn ->
        receive do: (:start_fault -> :ok)

        result =
          catch_exit(
            cond do
              repair_cut ->
                lookup(context, tx["tx_id"])

              header_cut ->
                RetainedObjects.open_run(owner, "create", context.ids, context.runtime)

              true ->
                commit(context, tx)
            end
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
      assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}, remaining(deadline)
      :atomics.put(joins, 1, 1)
      assert_receive {:ended, _}, remaining(deadline)
      assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, remaining(deadline)
      :atomics.put(joins, 2, 1)
      context = %{context | owner: open(context, recover_stale_writer: true)}
      classify_binding(context)
      assert {:ok, actual} = lookup(context, tx["tx_id"])
      {header, json, expected} = authored_bytes(context)

      if repair_cut or cut in [:run_header_synced, :run_partial_written] do
        assert actual == :absent
        assert File.read!(path(context)) == header
      else
        assert actual == expected
        assert File.read!(path(context)) == header <> framed(json)
      end
    after
      join_fault_actors(
        context,
        [{owner, monitor, 1}, {caller, caller_monitor, 2}],
        joins,
        deadline
      )
    end
  end

  defp partial_run(context) do
    armed = :atomics.new(1, [])
    context = bound(context, checkpoint: error_checkpoint(armed, :run_partial_written))

    assert {:ok, _} =
             RetainedObjects.open_run(context.owner, "create", context.ids, context.runtime)

    :atomics.put(armed, 1, 1)
    assert {:error, {:commit_unknown, _}} = commit(context, initialize(context))
    context
  end

  defp initialized(context) do
    context = bound(context)

    assert {:ok, _} =
             RetainedObjects.open_run(context.owner, "create", context.ids, context.runtime)

    assert {:ok, _} = commit(context, initialize(context))
    context
  end

  defp bound(context, options \\ [], adapter \\ Memory) do
    capture = Fixture.valid_capture()
    store_path = Path.join(context.root, "core.log")
    options_store = if adapter == Local, do: [path: store_path], else: []
    {:ok, first} = adapter.start_link(options_store)
    {:ok, store} = Store.new(adapter, first)
    {:committed, _, receipt} = Fixture.commit_creation(store, capture)

    store_pid =
      if adapter == Local do
        stop_join(first)
        {:ok, reopened} = Local.start_link(options_store)
        reopened
      else
        first
      end

    # Concept: the fixture owns the physical store through its cleanup join.
    # Technical depth: unlink before runtime startup so test-process exit cannot
    # race the on_exit callback's explicit original-store stop and DOWN proof.
    Process.unlink(store_pid)
    on_exit(fn -> if Process.alive?(store_pid), do: stop_join(store_pid) end)
    {:ok, store} = Store.new(adapter, store_pid)

    {:ok, runtime} =
      Loopex.start_link(runtime_id: "runtime", context_token_budget: 8_192, store: store)

    on_exit(fn -> if Runtime.alive?(runtime), do: Loopex.stop(runtime) end)

    assert :ok = Fixture.await_startup(runtime)
    owner = open(context, options)
    assert {:ok, _} = RetainedObjects.open_binding(owner, "create", capture.object_bytes)
    assert {:ok, _} = RetainedObjects.commit_binding(owner, "create", prepare(capture))

    {:ok, bind} =
      ParentBinding.transaction(
        capture.key,
        1,
        ParentBinding.bind_mutation(capture, receipt.session_id)
      )

    assert {:ok, _} = RetainedObjects.commit_binding(owner, "create", bind, runtime)

    Map.merge(context, %{
      capture: capture,
      runtime: runtime,
      owner: owner,
      session: receipt.session_id,
      ids: ["runtime", receipt.session_id, "run"],
      bind: bind,
      store_pid: store_pid,
      store_path: store_path,
      adapter: adapter
    })
  end

  defp open(context, options \\ []) do
    {:ok, owner} = RetainedObjects.open(context.root, "runtime", context.lease, options)

    on_exit(fn ->
      if :atomics.get(context.cleanup_guard, 1) == 1 and Process.alive?(owner),
        do: stop_join(owner)
    end)

    owner
  end

  defp classify_binding(context) do
    assert {:ok, _} =
             RetainedObjects.lookup_binding(
               context.owner,
               "create",
               context.bind["tx_id"],
               context.runtime
             )
  end

  defp initialize(context) do
    mutation = %{
      "kind" => "initialize",
      "binding_key" => context.capture.key,
      "catalog_sha256" => context.capture.creation["catalog_sha256"],
      "declaration_sha256" => context.capture.creation["declaration_sha256"],
      "limits" => context.capture.declaration
    }

    {:ok, tx} = RunMutation.transaction(context.ids, 0, mutation)
    tx
  end

  # Concept: literal JSON and raw framing independently state the physical contract.
  # Technical depth: these expected bytes use no ledger encoder or run reducer;
  # only the original scope and object digests vary with actual Core creation.
  defp authored_bytes(context) do
    identity = "[" <> Enum.map_join(context.ids, ",", &("\"" <> Base.encode64(&1) <> "\"")) <> "]"
    key = run_key(context.ids)

    header =
      ~s({"identity":#{identity},"identity_sha256":"#{key}","kind":"header","ledger_kind":"run","version":1})

    mutation =
      ~s({"binding_key":"#{context.capture.key}","catalog_sha256":"#{context.capture.creation["catalog_sha256"]}","declaration_sha256":"#{context.capture.creation["declaration_sha256"]}","kind":"initialize","limits":#{@limits_json}})

    tx_id = Fixture.hash("loopex:helper-tx:v1" <> <<0>> <> ~s(["#{key}","initialize",[]]))
    digest = Fixture.hash("loopex:helper-mutation:v1" <> <<0>> <> ~s(["#{key}",0,#{mutation}]))

    tx_json =
      ~s({"expected_version":0,"mutation":#{mutation},"mutation_digest":"#{digest}","tx_id":"#{tx_id}","version":1})

    result = %{
      "version" => 1,
      "tx_id" => tx_id,
      "ledger_version" => 1,
      "mutation_digest" => digest
    }

    {framed(header), tx_json, result}
  end

  defp run_key(ids) do
    identity = "[" <> Enum.map_join(ids, ",", &("\"" <> Base.encode64(&1) <> "\"")) <> "]"
    Fixture.hash("loopex:helper-run:v1" <> <<0>> <> identity)
  end

  defp framed(payload) do
    prefix = <<"LXPHELP1", 1::unsigned-big-16, byte_size(payload)::unsigned-big-32>>
    prefix <> :crypto.hash(:sha256, prefix) <> payload <> :crypto.hash(:sha256, payload)
  end

  defp prepare(capture) do
    {:ok, tx} = ParentBinding.transaction(capture.key, 0, ParentBinding.prepare_mutation(capture))
    tx
  end

  defp commit(context, tx),
    do: RetainedObjects.commit_run(context.owner, "create", context.ids, tx, context.runtime)

  defp read(context),
    do: RetainedObjects.read_run(context.owner, "create", context.ids, context.runtime)

  defp lookup(context, id),
    do: RetainedObjects.lookup_run(context.owner, "create", context.ids, id, context.runtime)

  defp path(context), do: Path.join([context.directory, "runs", run_key(context.ids) <> ".log"])
  defp store_image(%{adapter: Local} = context), do: File.read!(context.store_path)
  defp store_image(context), do: :sys.get_state(context.store_pid)

  defp error_checkpoint(armed, cut),
    do: fn step ->
      if step == cut and :atomics.compare_exchange(armed, 1, 1, 0) == :ok,
        do: {:error, :physical_cut},
        else: :ok
    end

  defp flip(bytes, offset) do
    <<before::binary-size(^offset), byte, rest::binary>> = bytes
    before <> <<Bitwise.bxor(byte, 1)>> <> rest
  end

  defp bad_length(size) do
    prefix = <<"LXPHELP1", 1::unsigned-big-16, size::unsigned-big-32>>
    prefix <> :crypto.hash(:sha256, prefix)
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp fault_run_io(context, _tx, cut, armed)
       when cut in [:run_header_written, :run_header_synced] do
    :atomics.put(armed, 1, 1)
    RetainedObjects.open_run(context.owner, "create", context.ids, context.runtime)
  end

  defp fault_run_io(context, tx, _cut, armed) do
    assert {:ok, _} =
             RetainedObjects.open_run(context.owner, "create", context.ids, context.runtime)

    :atomics.put(armed, 1, 1)
    commit(context, tx)
  end

  defp assert_io_error_recovery(context, tx, :run_partial_written) do
    assert lookup(context, tx["tx_id"]) == {:error, :run_recovery_unproved}
    stop_join(context.owner)
    context = %{context | owner: open(context, recover_stale_writer: true)}
    classify_binding(context)
    assert lookup(context, tx["tx_id"]) == {:ok, :absent}
    assert {:ok, _} = commit(context, tx)
  end

  defp assert_io_error_recovery(context, tx, cut) do
    {_header, _json, original} = authored_bytes(context)
    expected = if cut in [:run_header_written, :run_header_synced], do: :absent, else: original
    assert lookup(context, tx["tx_id"]) == {:ok, expected}
  end

  defp stop_join(pid) do
    monitor = Process.monitor(pid)
    :ok = GenServer.stop(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 5_000
  end

  # Concept: preserve the exact original fault actors and one pre-operation cutoff.
  # Technical depth: cleanup consumes their original monitors, and only proved
  # joins permit fixture deletion. It never substitutes a successor process.
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
            {:DOWN, ^monitor, :process, ^pid, _} ->
              :atomics.put(joins, index, 1)
              true
          after
            remaining(deadline) -> false
          end
        end
      end)

    if Enum.all?(proved),
      do: :atomics.put(context.cleanup_guard, 1, 1),
      else:
        flunk(
          "Original fault actor cleanup exceeded its captured cutoff; retaining #{context.root}"
        )
  end

  # Concept: physical roots must not traverse a symlinked temporary directory.
  # Technical depth: macOS /tmp is a symlink to /private/tmp, which the owner
  # refuses; other hosts use their ordinary non-symlinked /tmp.
  defp physical_tmp, do: if(File.dir?("/private/tmp"), do: "/private/tmp", else: "/tmp")
end
