Code.require_file("support/m5_query_fault_store.exs", __DIR__)
Code.require_file("support/configured_genesis_helper.exs", __DIR__)

defmodule Loopex.CreationProvenanceTest do
  use ExUnit.Case, async: false

  alias Loopex.Runtime
  alias Loopex.Store
  alias Loopex.Store.CreationProvenance

  defmodule FaultStore do
    @moduledoc false
    @behaviour Store
    @impl Store
    defdelegate transact(reference, transaction), to: Loopex.M5QueryFaultStore
    @impl Store
    defdelegate transaction_status(reference, session, domain, tx), to: Loopex.M5QueryFaultStore
    @impl Store
    defdelegate runtime_command(reference, command), to: Loopex.M5QueryFaultStore
    @impl Store
    defdelegate ownership_head(reference, session, domain), to: Loopex.M5QueryFaultStore
    @impl Store
    defdelegate load_records(reference, session, after_version, limit),
      to: Loopex.M5QueryFaultStore

    @impl Store
    defdelegate load_events(reference, session, after_sequence, limit),
      to: Loopex.M5QueryFaultStore

    @impl Store
    def creation_provenance(:kill_reader, _, _), do: Process.exit(self(), :kill)

    def creation_provenance({:observed, observer, result}, runtime, selector) do
      send(observer, {:provenance_callback_invoked, self(), runtime, selector})
      result
    end

    def creation_provenance({:controlled, observer, result}, _, _) do
      send(observer, {:provenance_reader_started, self()})

      receive do
        :release_provenance_reader -> result
      end
    end

    def creation_provenance(:raise, _, _), do: raise("unavailable callback")
    def creation_provenance(result, _, _), do: result
  end

  @row %{
    version: 1,
    runtime_id: "runtime",
    command_id: "create",
    session_id: "session",
    genesis_version: 3,
    canonical_create_digest: String.duplicate("a", 64)
  }

  test "closed selectors retain scoped cursor and exact scalar bounds" do
    for selector <- [
          %{kind: :command, command_id: "create"},
          %{kind: :session, session_id: "session"},
          %{kind: :runtime_page, cursor: nil, limit: 16}
        ] do
      assert CreationProvenance.valid_selector?("runtime", selector)
      refute CreationProvenance.valid_selector?("runtime", Map.put(selector, :extra, nil))

      for key <- Map.keys(selector),
          do: refute(CreationProvenance.valid_selector?("runtime", Map.delete(selector, key)))
    end

    cursor = %{
      version: 1,
      runtime_id: "runtime",
      through_create_ordinal: 3,
      after_create_ordinal: 1
    }

    valid = %{kind: :runtime_page, cursor: cursor, limit: 2}
    assert CreationProvenance.valid_selector?("runtime", valid)

    for invalid <- [
          nil,
          %{},
          %{kind: "command", command_id: "create"},
          %{kind: :command, command_id: ""},
          %{kind: :session, session_id: String.duplicate("x", 257)},
          %{valid | limit: 0},
          %{valid | limit: 17},
          %{valid | limit: "2"},
          %{valid | cursor: %{cursor | version: 2}},
          %{valid | cursor: %{cursor | runtime_id: "another"}},
          %{valid | cursor: %{cursor | after_create_ordinal: 4}},
          %{valid | cursor: %{cursor | through_create_ordinal: 18_446_744_073_709_551_616}},
          %{valid | cursor: Map.put(cursor, :extra, true)}
        ] do
      refute CreationProvenance.valid_selector?("runtime", invalid)
    end
  end

  test "historical projections bind selector identity and reject unsupported or expanded output" do
    selector = %{kind: :command, command_id: "create"}

    assert CreationProvenance.normalize("runtime", selector, {:historical, @row}) ==
             {:historical, @row}

    assert CreationProvenance.normalize(
             "runtime",
             %{kind: :session, session_id: "session"},
             {:historical, @row}
           ) == {:historical, @row}

    for row <-
          Enum.map(Map.keys(@row), &Map.delete(@row, &1)) ++
            [
              Map.put(@row, :extra, nil),
              %{@row | runtime_id: "other"},
              %{@row | command_id: "other"},
              %{@row | genesis_version: 1},
              %{@row | genesis_version: 2},
              %{@row | canonical_create_digest: String.duplicate("A", 64)},
              %{@row | session_id: String.duplicate("x", 65_537)}
            ] do
      assert CreationProvenance.normalize("runtime", selector, {:historical, row}) == :unavailable
    end
  end

  test "pages require contiguous complete rows and the unchanged captured watermark" do
    selector = %{kind: :runtime_page, cursor: nil, limit: 2}

    rows =
      for ordinal <- [1, 2],
          do:
            Map.merge(@row, %{
              create_ordinal: ordinal,
              command_id: "create-#{ordinal}",
              session_id: "session-#{ordinal}"
            })

    cursor = CreationProvenance.cursor("runtime", 3, 2)

    page = %{
      version: 1,
      runtime_id: "runtime",
      through_create_ordinal: 3,
      rows: rows,
      next_cursor: cursor
    }

    assert CreationProvenance.normalize("runtime", selector, {:page, page}) == {:page, page}

    tail = %{
      page
      | rows: [
          Map.merge(@row, %{create_ordinal: 3, command_id: "create-3", session_id: "session-3"})
        ],
        next_cursor: nil
    }

    assert CreationProvenance.normalize("runtime", %{selector | cursor: cursor}, {:page, tail}) ==
             {:page, tail}

    for invalid <- [
          %{page | rows: []},
          %{page | rows: [hd(rows)]},
          %{page | rows: Enum.reverse(rows)},
          %{page | rows: [hd(rows), Map.put(hd(rows), :create_ordinal, 2)]},
          %{page | rows: [hd(rows), Map.put(Enum.at(rows, 1), :command_id, hd(rows).command_id)]},
          %{page | rows: [hd(rows), Map.put(Enum.at(rows, 1), :session_id, hd(rows).session_id)]},
          %{page | rows: rows ++ [hd(rows)]},
          %{page | next_cursor: nil},
          %{page | next_cursor: %{cursor | through_create_ordinal: 4}},
          %{page | runtime_id: "another"},
          Map.put(page, :extra, nil)
        ] do
      assert CreationProvenance.normalize("runtime", selector, {:page, invalid}) == :unavailable
    end

    assert CreationProvenance.normalize(
             "runtime",
             %{selector | cursor: cursor},
             {:page, %{tail | through_create_ordinal: 4}}
           ) == :unavailable

    assert CreationProvenance.normalize("runtime", selector, :absent) == :unavailable
    assert CreationProvenance.normalize("runtime", selector, :conflict) == :unexpected
  end

  test "runtime never converts missing callbacks or malformed output into absence" do
    for {adapter, reference, expected} <- [
          {Loopex.M5QueryFaultStore, :absent, :store_unavailable},
          {FaultStore, {:historical, @row}, {:historical, @row}},
          {FaultStore, :absent, :absent},
          {FaultStore, :conflict, :conflict},
          {FaultStore, :unavailable, :store_unavailable},
          {FaultStore, :raise, :store_unavailable},
          {FaultStore, {:historical, %{@row | session_id: nil}}, :store_unavailable}
        ] do
      runtime = start_runtime(adapter, reference)
      {:ok, %{sessions: supervisor}} = Runtime.children(runtime)

      assert {:ok, ^expected} =
               Runtime.creation_provenance(runtime, %{kind: :command, command_id: "create"})

      assert {:ok, :unexpected} =
               Runtime.creation_provenance(runtime, %{
                 kind: :command,
                 command_id: "create",
                 extra: true
               })

      assert DynamicSupervisor.which_children(supervisor) == []
      :ok = Loopex.stop(runtime)
    end
  end

  test "provenance reader failure remains Store unavailability with live Control" do
    runtime = start_runtime(FaultStore, :kill_reader)
    {:ok, %{control: control}} = Runtime.children(runtime)

    assert {:ok, :store_unavailable} =
             Runtime.creation_provenance(runtime, %{kind: :session, session_id: "session"})

    assert Process.alive?(control)
    assert {:ok, %{control: ^control}} = Runtime.children(runtime)

    assert {:ok, :unexpected} =
             Runtime.creation_provenance(runtime, %{kind: :command, command_id: ""})
  end

  test "provenance success joins its original reader and guardian before answering" do
    runtime = start_runtime(FaultStore, {:controlled, self(), {:historical, @row}})
    {:ok, %{control: control}} = Runtime.children(runtime)
    selector = %{kind: :command, command_id: "create"}

    with_provenance_reader(runtime, selector, fn task, reader, guardian, _cleanup_cutoff ->
      caller = task.pid
      caller_monitor = Process.monitor(caller)
      refute reader == control
      reader_monitor = Process.monitor(reader)
      guardian_monitor = Process.monitor(guardian)
      send(reader, :release_provenance_reader)

      assert {:ok, {:historical, @row}} = Task.await(task, 5_000)
      refute Process.alive?(reader)
      refute Process.alive?(guardian)
      assert_receive {:DOWN, ^reader_monitor, :process, ^reader, :normal}, 5_000
      assert_receive {:DOWN, ^guardian_monitor, :process, ^guardian, :normal}, 5_000
      assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 5_000
      assert {:ok, %{control: ^control}} = Runtime.children(runtime)
    end)
  end

  test "provenance timeout joins its original blocked reader before answering" do
    runtime = start_runtime(FaultStore, {:controlled, self(), :absent})
    {:ok, %{control: control}} = Runtime.children(runtime)
    selector = %{kind: :session, session_id: "session"}

    with_provenance_reader(runtime, selector, fn task, reader, guardian, _cleanup_cutoff ->
      caller = task.pid
      caller_monitor = Process.monitor(caller)
      refute reader == control
      reader_monitor = Process.monitor(reader)
      guardian_monitor = Process.monitor(guardian)

      assert {:ok, :store_unavailable} = Task.await(task, 5_000)
      refute Process.alive?(reader)
      refute Process.alive?(guardian)
      assert_receive {:DOWN, ^reader_monitor, :process, ^reader, :killed}, 5_000
      assert_receive {:DOWN, ^guardian_monitor, :process, ^guardian, :normal}, 5_000
      assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 5_000
      assert Process.alive?(control)
      assert {:ok, %{control: ^control}} = Runtime.children(runtime)

      assert {:ok, :unexpected} =
               Runtime.creation_provenance(runtime, %{kind: :command, command_id: ""})
    end)
  end

  test "provenance Control loss remains runtime unavailability" do
    runtime = start_runtime(FaultStore, {:controlled, self(), :absent})
    {:ok, %{control: control}} = Runtime.children(runtime)
    selector = %{kind: :session, session_id: "session"}

    with_provenance_reader(runtime, selector, fn task, reader, guardian, cleanup_cutoff ->
      caller = task.pid
      caller_monitor = Process.monitor(caller)
      refute reader == control
      reader_monitor = Process.monitor(reader)
      guardian_monitor = Process.monitor(guardian)
      control_monitor = Process.monitor(control)
      control_cleanup_monitor = Process.monitor(control)

      try do
        Process.exit(control, :kill)

        assert {:error, :runtime_unavailable} = Task.await(task, 5_000)
        assert_receive {:DOWN, ^control_monitor, :process, ^control, :killed}, 5_000
        assert_receive {:DOWN, ^reader_monitor, :process, ^reader, :killed}, 5_000
        assert_receive {:DOWN, ^guardian_monitor, :process, ^guardian, :normal}, 5_000
        assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 5_000

        assert {:error, :runtime_unavailable} =
                 Runtime.creation_provenance(nil, %{kind: :command, command_id: "create"})
      after
        Process.exit(control, :kill)
        join_provenance_actor(control, control_cleanup_monitor, cleanup_cutoff)
      end
    end)
  end

  test "a wrong token refuses before Store dispatch on the original Control" do
    runtime = start_runtime(FaultStore, {:observed, self(), {:historical, @row}})
    {:ok, %{control: control}} = Runtime.children(runtime)
    selector = %{kind: :command, command_id: "create"}
    wrong_token = make_ref()
    refute wrong_token == runtime.token

    assert {:error, :runtime_unavailable} =
             GenServer.call(control, {:creation_provenance, wrong_token, selector}, 5_000)

    # Concept: the completed serial refusal is the no-dispatch barrier.
    # Technical depth: the same original Control must then complete the valid
    # query and expose its actual callback notification, so an unavailable Store
    # or unused notification fixture cannot manufacture this authentication proof.
    refute_receive {:provenance_callback_invoked, _, _, _}, 0

    assert {:ok, {:historical, @row}} =
             GenServer.call(control, {:creation_provenance, runtime.token, selector}, 5_000)

    assert_receive {:provenance_callback_invoked, reader, "runtime", ^selector}, 5_000
    refute reader == control
    refute_receive {:provenance_callback_invoked, _, _, _}, 0
    assert Process.alive?(control)
    assert {:ok, %{control: ^control}} = Runtime.children(runtime)
  end

  # Concept: failed fixture assertions still retire every discovered original actor.
  # Technical depth: cleanup monitors are installed before release or kill and are
  # distinct from reason-specific proof monitors. One captured five-second fixture
  # allowance covers all joins; cleanup never monitors an already-retired replacement.
  defp with_provenance_reader(runtime, selector, proof) do
    task = Task.async(fn -> Runtime.creation_provenance(runtime, selector) end)
    caller = task.pid
    caller_cleanup_monitor = Process.monitor(caller)
    cleanup_cutoff = System.monotonic_time(:millisecond) + 5_000

    try do
      assert_receive {:provenance_reader_started, reader}, 5_000
      guardian_snapshot = Process.info(reader, :monitored_by)
      reader_cleanup_monitor = Process.monitor(reader)

      try do
        assert {:monitored_by, [guardian]} = guardian_snapshot
        guardian_cleanup_monitor = Process.monitor(guardian)

        try do
          proof.(task, reader, guardian, cleanup_cutoff)
        after
          send(reader, :release_provenance_reader)
          join_provenance_actor(guardian, guardian_cleanup_monitor, cleanup_cutoff)
        end
      after
        Process.exit(reader, :kill)
        join_provenance_actor(reader, reader_cleanup_monitor, cleanup_cutoff)
      end
    after
      Process.unlink(caller)
      Process.exit(caller, :kill)
      join_provenance_actor(caller, caller_cleanup_monitor, cleanup_cutoff)
      Process.demonitor(task.ref, [:flush])
    end
  end

  defp join_provenance_actor(actor, monitor, cutoff) do
    remaining = max(cutoff - System.monotonic_time(:millisecond), 0)
    assert_receive {:DOWN, ^monitor, :process, ^actor, _reason}, remaining
    assert System.monotonic_time(:millisecond) <= cutoff
    refute Process.alive?(actor)
  end

  defp start_runtime(adapter, reference) do
    {:ok, store} = Store.new(adapter, reference)

    {:ok, runtime} =
      Loopex.start_link(runtime_id: "runtime", context_token_budget: 8_192, store: store)

    on_exit(fn -> if Runtime.alive?(runtime), do: Loopex.stop(runtime) end)
    :ok = Loopex.ConfiguredGenesisFixture.await_creation_unavailable(runtime)
    runtime
  end
end
