Code.require_file("../../loopex/test/support/configured_genesis_helper.exs", __DIR__)
Code.require_file("support/store_conformance_helper.exs", __DIR__)

defmodule Loopex.Store.CreationStorageTest do
  @moduledoc """
  ## Concept

  Creation ownership exists before a session and resolves to exactly one
  original created session or a retained cancellation.

  ## Technical depth

  These cases exercise shared pure transitions, both shipped callbacks,
  current-format replay and Local process-loss recovery. A stopped-log copy
  proves Store custody preservation, not the complete physical restore path.
  """

  use ExUnit.Case, async: false

  alias Loopex.Store
  alias Loopex.Store.Local.State
  alias Loopex.Store.Memory
  alias LoopexStoreLocalTest.FaultProbe

  @runtime "creation-storage-runtime"
  @selection String.duplicate("a", 64)
  @next_selection String.duplicate("b", 64)
  @uint64 18_446_744_073_709_551_615

  test "an absent runtime returns the exact zero head and no command" do
    assert {:ok, %{version: 1, runtime_id: @runtime, command: nil, head: head}} =
             read(State.new(), nil)

    assert head == %{
             version: 1,
             owner_generation: 0,
             owner_selection: nil,
             domain_version: 0,
             active_command_id: nil
           }

    assert {:ok, %{command: nil, head: ^head}} = read(State.new(), "absent")
    assert {:error, :invalid_creation_recovery} = State.creation_recovery(State.new(), %{})
  end

  test "claim advances only generation and an exact old receipt grants no current selection" do
    claim = claim(0)
    {state, first} = apply_new(State.new(), claim)
    {next, _receipt} = apply_new(state, claim(1, @next_selection))
    assert {:known, ^first} = State.prepare(next, claim)

    assert {:ok,
            %{
              head: %{
                owner_generation: 2,
                owner_selection: @next_selection,
                domain_version: 0,
                active_command_id: nil
              }
            }} = read(next, nil)

    assert next.sessions == %{} and next.runtime_commands == %{}
    assert next.creation_capsules == %{} and next.next_session_number == 1
  end

  test "contending claims have one winner in both serial orders" do
    first = claim(0)
    second = claim(0, @next_selection)

    for {winner, loser} <- [{first, second}, {second, first}] do
      {state, _} = apply_new(State.new(), winner)
      {refused, {:not_committed, :stale_creation_generation}} = apply_new(state, loser)
      assert refused.creation_heads == state.creation_heads

      assert {:known, {:not_committed, :stale_creation_generation}} =
               State.prepare(refused, loser)
    end
  end

  test "reserve retains the complete original capsule without session or public facts" do
    {state, claim_receipt} = apply_new(State.new(), claim(0))
    reserve = reserve("first", claim_receipt)
    {state, {:committed, id, receipt}} = apply_new(state, reserve)
    assert id == reserve.tx_id
    assert receipt.owner_generation == 2 and receipt.domain_version == 1
    assert {:ok, %{command: capsule, head: %{active_command_id: "first"}}} = read(state, nil)
    assert capsule.genesis == reserve.genesis and capsule.state == :reserved
    assert capsule.reservation_owner_generation == 1
    assert capsule.reservation_domain_version == 1
    assert capsule.final_resolution == nil and capsule.session_id == nil
    assert state.sessions == %{} and state.runtime_commands == %{}
    assert state.create_ordinals == %{} and state.creation_rows == %{}
    assert state.next_session_number == 1
    assert {:ok, %{command: ^capsule}} = read(state, "first")
    assert {:ok, %{command: nil}} = read(state, "other")
  end

  test "a successor claim preserves the reservation and an already-permitted final may win" do
    {state, final, _reserve, _receipt} = reserved("first")
    before = state.creation_capsules
    {state, _} = apply_new(state, claim(2, @next_selection))
    assert state.creation_capsules == before
    {state, {:committed, "first", receipt}} = apply_new(state, final)

    assert {:ok,
            %{
              head: %{
                owner_generation: 4,
                domain_version: 2,
                owner_selection: @next_selection,
                active_command_id: nil
              },
              command: %{state: :created, session_id: session}
            }} = read(state, "first")

    assert session == receipt.session_id
    assert map_size(state.sessions) == 1
  end

  test "a delayed reserve loses to a successor claim and retains no logical command" do
    {state, receipt} = apply_new(State.new(), claim(0))
    delayed = reserve("delayed", receipt)
    {state, _} = apply_new(state, claim(1, @next_selection))
    {refused, {:not_committed, :stale_creation_generation}} = apply_new(state, delayed)
    assert refused.creation_capsules == %{} and refused.runtime_commands == %{}
    assert refused.creation_heads == state.creation_heads

    assert {:known, {:not_committed, :stale_creation_generation}} =
             State.prepare(refused, delayed)
  end

  test "occupied reserve and changed reservation bytes cannot replace the active candidate" do
    {state, _final, reservation, receipt} = reserved("first")
    occupied = reserve("other", {:committed, "unused", receipt})
    {refused, {:not_committed, :creation_in_progress}} = apply_new(state, occupied)
    assert refused.creation_capsules == state.creation_capsules

    {:ok, changed} =
      Store.reserve_creation(@runtime, "first", 1, @selection, 0, genesis("changed"))

    assert changed.tx_id == reservation.tx_id
    assert {:known, {:not_committed, :tx_id_conflict}} = State.prepare(refused, changed)
    assert {:known, {:committed, id, ^receipt}} = State.prepare(refused, reservation)
    assert id == reservation.tx_id
  end

  test "final wins before close and repeated close never changes the created session" do
    {state, final, reservation, receipt} = reserved("first")
    close = close(final, reservation, receipt)
    {state, {:committed, "first", created}} = apply_new(state, final)
    before = state.creation_heads
    {closed, {:committed, id, outcome}} = apply_new(state, close)
    assert id == close.tx_id and outcome.final_resolution == :committed
    assert outcome.session_id == created.session_id
    assert closed.creation_heads == before and closed.sessions == state.sessions
    assert {:known, {:committed, ^id, ^outcome}} = State.prepare(closed, close)
    assert {:known, {:committed, "first", ^created}} = State.prepare(closed, final)
  end

  test "close wins before final and all delayed finals return original cancellation" do
    {state, final, reservation, receipt} = reserved("first")
    close = close(final, reservation, receipt)
    {state, {:committed, id, outcome}} = apply_new(state, close)
    assert id == close.tx_id and outcome.final_resolution == {:not_committed, :creation_cancelled}
    assert outcome.session_id == nil and outcome.active_command_id == nil
    assert {:known, {:not_committed, :creation_cancelled}} = State.prepare(state, final)
    assert state.sessions == %{} and state.next_session_number == 1
    assert state.creation_rows == %{} and state.create_ordinals == %{}

    assert {:ok,
            %{
              command: %{state: :not_committed, session_id: nil},
              head: %{owner_generation: 3, domain_version: 2, active_command_id: nil}
            }} = read(state, "first")

    assert {:not_committed, :creation_cancelled} = State.runtime_command(state, command(final))
  end

  test "a changed cancelled command conflicts without changing terminal history" do
    {state, final, reservation, receipt} = reserved("first")
    {state, _} = apply_new(state, close(final, reservation, receipt))
    {:ok, changed} = Store.create_session(@runtime, "first", genesis("changed"))
    assert {:known, {:not_committed, :tx_id_conflict}} = State.prepare(state, changed)
    assert {:error, :runtime_command_conflict} = State.runtime_command(state, command(changed))
    assert {:known, {:not_committed, :creation_cancelled}} = State.prepare(state, final)
  end

  test "a historical terminal close cannot release or advance another active command" do
    {state, final, reservation, receipt} = reserved("first")
    {state, _} = apply_new(state, close(final, reservation, receipt))
    {state, claimed} = apply_new(state, claim(3, @next_selection))
    next_reserve = reserve("second", claimed)
    {state, _} = apply_new(state, next_reserve)
    {:ok, %{head: head}} = read(state, nil)

    {:ok, historical_close} =
      Store.close_creation_reservation(
        @runtime,
        "first",
        head.owner_generation,
        head.owner_selection,
        head.domain_version,
        reservation.tx_id,
        receipt.reservation_domain_version,
        final
      )

    {closed, {:committed, _, result}} = apply_new(state, historical_close)
    assert result.final_resolution == {:not_committed, :creation_cancelled}
    assert result.active_command_id == "second"
    assert closed.creation_heads == state.creation_heads
    assert closed.creation_capsules == state.creation_capsules

    assert {:ok, %{command: %{command_id: "first", state: :not_committed}}} =
             read(closed, "first")

    assert {:ok, %{command: %{command_id: "second", state: :reserved}}} = read(closed, nil)
  end

  test "a wrong reservation close cannot cancel the active final" do
    {state, final, _reservation, receipt} = reserved("first")

    {:ok, wrong} =
      Store.close_creation_reservation(
        @runtime,
        "first",
        receipt.owner_generation,
        receipt.owner_selection,
        receipt.domain_version,
        "wrong-reservation",
        receipt.domain_version,
        final
      )

    {refused, {:not_committed, :creation_reservation_conflict}} = apply_new(state, wrong)
    assert refused.creation_heads == state.creation_heads
    assert refused.creation_capsules == state.creation_capsules
    {created, {:committed, "first", _}} = apply_new(refused, final)
    assert map_size(created.sessions) == 1
  end

  test "a changed final before commitment cannot poison the reserved original binding" do
    {state, final, _reservation, _receipt} = reserved("first")
    {:ok, changed} = Store.create_session(@runtime, "first", genesis("changed"))
    assert {:invalid, {:not_committed, :tx_id_conflict}} = State.prepare(state, changed)
    {state, {:committed, "first", _}} = apply_new(state, final)
    assert map_size(state.sessions) == 1
  end

  test "unreserved final refusal is retained and cannot later borrow a reservation" do
    {:ok, final} = Store.create_session(@runtime, "unreserved", genesis())
    {state, {:not_committed, :creation_reservation_required}} = apply_new(State.new(), final)
    assert state.sessions == %{} and state.creation_capsules == %{}
    {state, claimed} = apply_new(state, claim(0))

    {state, {:not_committed, :runtime_command_conflict}} =
      apply_new(state, reserve("unreserved", claimed))

    assert {:known, {:not_committed, :creation_reservation_required}} =
             State.prepare(state, final)

    assert state.creation_capsules == %{}
  end

  test "equal digest with changed canonical bytes never closes or creates" do
    {state, final, reservation, receipt} = reserved("first")
    bad_final = %{final | canonical_record_bytes: final.canonical_record_bytes <> <<0>>}
    assert {:invalid, {:not_committed, :invalid_transaction}} = State.prepare(state, bad_final)
    close = close(final, reservation, receipt)

    bad_close = %{
      close
      | final_canonical_record_bytes: close.final_canonical_record_bytes <> <<0>>
    }

    assert {:invalid, {:not_committed, :invalid_transaction}} = State.prepare(state, bad_close)
    assert {:ok, %{command: %{state: :reserved}}} = read(state, nil)
  end

  test "new family resolution keys remain distinct from final command history" do
    {state, final, reservation, receipt} = reserved("first")
    close = close(final, reservation, receipt)
    {state, _} = apply_new(state, close)

    assert MapSet.new(Map.keys(state.creation_resolutions)) ==
             MapSet.new([
               {@runtime, :claim_creation_domain, claim(0).tx_id},
               {@runtime, :reserve_creation, reservation.tx_id},
               {@runtime, :close_creation_reservation, close.tx_id}
             ])

    assert Map.keys(state.runtime_commands[@runtime]) == ["first"]
  end

  test "runtime domains do not share heads capsules or final resolutions" do
    {state, final, reservation, receipt} = reserved("first")
    {state, _} = apply_new(state, close(final, reservation, receipt))
    {:ok, other_claim} = Store.claim_creation_domain("other", 0, @selection)
    {state, other_receipt} = apply_new(state, other_claim)
    {:committed, _, r} = other_receipt

    {:ok, other_reserve} =
      Store.reserve_creation(
        "other",
        "first",
        r.owner_generation,
        r.owner_selection,
        r.domain_version,
        genesis()
      )

    {state, _} = apply_new(state, other_reserve)

    assert {:ok, %{command: %{state: :reserved, runtime_id: "other"}}} =
             State.creation_recovery(state, %{runtime_id: "other", command_id: nil})

    assert {:ok, %{command: %{state: :not_committed}}} = read(state, "first")
  end

  test "empty claim refuses counter exhaustion without wrapping or installing selection" do
    head = %{
      version: 1,
      owner_generation: @uint64 - 2,
      owner_selection: @selection,
      domain_version: 0,
      active_command_id: nil
    }

    state = %{State.new() | creation_heads: %{@runtime => head}}

    {refused, {:not_committed, :creation_counter_exhausted}} =
      apply_new(state, claim(@uint64 - 2))

    assert refused.creation_heads == state.creation_heads
  end

  test "reserve leaves enough headroom for a terminal close at the maximum counters" do
    head = %{
      version: 1,
      owner_generation: @uint64 - 2,
      owner_selection: @selection,
      domain_version: @uint64 - 3,
      active_command_id: nil
    }

    state = %{State.new() | creation_heads: %{@runtime => head}}

    {:ok, reservation} =
      Store.reserve_creation(
        @runtime,
        "edge",
        head.owner_generation,
        head.owner_selection,
        head.domain_version,
        genesis()
      )

    {state, {:committed, _, receipt}} = apply_new(state, reservation)
    {:ok, final} = Store.create_session(@runtime, "edge", genesis())
    {state, _} = apply_new(state, close(final, reservation, receipt))

    assert {:ok,
            %{
              head: %{owner_generation: @uint64, domain_version: version},
              command: %{state: :not_committed}
            }} = read(state, "edge")

    assert version == @uint64 - 1
    assert {:known, {:not_committed, :creation_cancelled}} = State.prepare(state, final)
  end

  test "an active successor claim refuses if it would consume terminal headroom" do
    {state, _final, _reservation, _receipt} = reserved("first")
    head = %{state.creation_heads[@runtime] | owner_generation: @uint64 - 1}
    state = %{state | creation_heads: %{@runtime => head}}

    {refused, {:not_committed, :creation_counter_exhausted}} =
      apply_new(state, claim(@uint64 - 1, @next_selection))

    assert refused.creation_heads == state.creation_heads
    assert refused.creation_capsules == state.creation_capsules
  end

  test "reserve rejects exhausted increments before installing a capsule" do
    head = %{
      version: 1,
      owner_generation: @uint64 - 1,
      owner_selection: @selection,
      domain_version: 0,
      active_command_id: nil
    }

    state = %{State.new() | creation_heads: %{@runtime => head}}

    {:ok, reservation} =
      Store.reserve_creation(
        @runtime,
        "edge",
        head.owner_generation,
        head.owner_selection,
        head.domain_version,
        genesis()
      )

    {refused, {:not_committed, :creation_counter_exhausted}} = apply_new(state, reservation)
    assert refused.creation_heads == state.creation_heads
    assert refused.creation_capsules == %{} and refused.runtime_commands == %{}
  end

  test "missing active lineage and changed capsule provenance are unavailable" do
    {state, _final, reservation, _receipt} = reserved("first")
    missing = %{state | creation_capsules: %{}}
    assert :unavailable = read(missing, nil)
    assert :unavailable = read(missing, "other")
    capsule = state.creation_capsules[{@runtime, "first"}]

    changed = %{
      state
      | creation_capsules: %{{@runtime, "first"} => %{capsule | genesis: genesis("changed")}}
    }

    assert :unavailable = read(changed, nil)

    missing_receipt = %{
      state
      | creation_resolutions:
          Map.delete(
            state.creation_resolutions,
            {@runtime, :reserve_creation, reservation.tx_id}
          )
    }

    assert :unavailable = read(missing_receipt, nil)
  end

  test "a reserved capsule cannot hide a later domain version or impossible G V relation" do
    {state, _final, _reservation, _receipt} = reserved("first")
    head = state.creation_heads[@runtime]

    for damaged <- [
          %{head | domain_version: 2},
          %{head | owner_generation: 1},
          %{head | owner_generation: head.domain_version}
        ] do
      assert :unavailable = read(%{state | creation_heads: %{@runtime => damaged}}, nil)
    end
  end

  test "created recovery checks exact retained final and actual session genesis" do
    {state, final, _reservation, _receipt} = reserved("first")
    {state, {:committed, _, receipt}} = apply_new(state, final)
    assert :unavailable = read(%{state | runtime_commands: %{}}, "first")
    session = state.sessions[receipt.session_id]
    changed = %{session | records: [%{hd(session.records) | payload: genesis("changed")}]}
    assert :unavailable = read(%{state | sessions: %{receipt.session_id => changed}}, "first")
  end

  test "all prospective replies fit with the largest legal session identifier and a large genesis" do
    large = genesis() |> Map.put("options", %{"padding" => String.duplicate("x", 60_000)})
    {state, claimed} = apply_new(State.new(), claim(0))
    reservation = reserve("large", claimed, large)
    {state, _} = apply_new(state, reservation)
    {:ok, reply} = read(state, "large")
    assert byte_size(:erlang.term_to_binary(reply, [:deterministic])) <= 1_048_576
    assert reply.command.genesis == large

    maximum = %{
      reply.command
      | state: :created,
        final_resolution: :committed,
        session_id: String.duplicate("s", 256)
    }

    assert byte_size(:erlang.term_to_binary(%{reply | command: maximum}, [:deterministic])) <=
             1_048_576

    too_large = genesis() |> Map.put("options", %{"padding" => String.duplicate("x", 65_536)})

    assert {:error, _} =
             Store.reserve_creation(@runtime, "oversized", 1, @selection, 0, too_large)

    assert map_size(state.creation_capsules) == 1
  end

  test "the Memory callback exposes atomic custody and exact native cancellation" do
    {:ok, pid} = Memory.start_link()

    try do
      {:ok, store} = Store.new(Memory, pid)
      {:committed, _, claimed} = Store.transact(store, claim(0))
      reservation = reserve("first", {:committed, "unused", claimed})
      {:committed, _, receipt} = Store.transact(store, reservation)
      {:ok, final} = Store.create_session(@runtime, "first", genesis())
      {:committed, _, _} = Store.transact(store, close(final, reservation, receipt))
      assert {:not_committed, :creation_cancelled} = Store.transact(store, final)
      assert {:not_committed, :creation_cancelled} = Store.runtime_command(store, command(final))

      assert {:ok, %{command: %{state: :not_committed}, head: %{active_command_id: nil}}} =
               Store.creation_recovery(store, %{runtime_id: @runtime, command_id: "first"})

      assert {:ok, []} = Store.load_records(store, "absent", 0, 1)
    after
      stop_joined(pid)
    end
  end

  test "all three Memory creation transitions exercise every declared fault phase" do
    transitions = [
      :runtime_control_claim_creation_domain,
      :runtime_control_reserve_creation,
      :runtime_control_close_creation_reservation
    ]

    phases = [:before_linearization, :after_linearization_before_result, :recovery_representation]

    for transition <- transitions, phase <- phases do
      pair = {transition, phase}
      probe = FaultProbe.start(%{pair => [:return_unknown]})

      try do
        {:ok, pid} = Memory.start_link(fault_probe: probe)

        try do
          {:ok, store} = Store.new(Memory, pid)
          transaction = fault_transaction(store, transition)
          {:ok, id} = Store.transaction_id(transaction)

          if phase == :recovery_representation do
            assert {:committed, ^id, _} = Store.transact(store, transaction)
          end

          assert {:commit_unknown, ^id} = Store.transact(store, transaction)
          assert {:committed, ^id, receipt} = Store.transact(store, transaction)
          assert {:committed, ^id, ^receipt} = Store.transact(store, transaction)
          assert FaultProbe.injected(probe) == [pair]
        after
          stop_joined(pid)
        end
      after
        stop_probe_joined(probe)
      end
    end
  end

  test "Memory final and close contenders produce exactly one allowed terminal outcome" do
    {:ok, pid} = Memory.start_link()

    try do
      {:ok, store} = Store.new(Memory, pid)
      claimed = Store.transact(store, claim(0))
      reservation = reserve("race", claimed)
      {:committed, _, receipt} = Store.transact(store, reservation)
      {:ok, final} = Store.create_session(@runtime, "race", genesis())
      close = close(final, reservation, receipt)

      with_race_actor(store, :final, final, fn first ->
        with_race_actor(store, :close, close, fn second ->
          actors = [first, second]
          work_cutoff = System.monotonic_time(:millisecond) + 30_000
          Enum.each(actors, fn {actor, _} -> send(actor, :invoke) end)

          results =
            for {actor, _} <- actors do
              assert_receive {:creation_race, ^actor, kind, outcome},
                             max(work_cutoff - System.monotonic_time(:millisecond), 0)

              {kind, outcome}
            end

          join_cutoff = System.monotonic_time(:millisecond) + 1_000

          Enum.each(actors, fn {actor, monitor} ->
            assert_receive {:DOWN, ^monitor, :process, ^actor, :normal},
                           max(join_cutoff - System.monotonic_time(:millisecond), 0)
          end)

          {:ok, %{command: capsule}} =
            Store.creation_recovery(store, %{runtime_id: @runtime, command_id: "race"})

          close_id = close.tx_id

          case capsule.state do
            :created ->
              assert [
                       {:final, {:committed, "race", created}},
                       {:close, {:committed, ^close_id, closed}}
                     ] = results

              assert created.session_id == capsule.session_id and
                       closed.session_id == capsule.session_id

              assert closed.final_resolution == :committed

            :not_committed ->
              assert [
                       {:final, {:not_committed, :creation_cancelled}},
                       {:close, {:committed, ^close_id, closed}}
                     ] = results

              assert closed.final_resolution == {:not_committed, :creation_cancelled}
              assert closed.session_id == nil
          end
        end)
      end)
    after
      stop_joined(pid)
    end
  end

  test "current version two frames rebuild active created and cancelled custody exactly" do
    for terminal <- [:reserved, :created, :cancelled] do
      claim = claim(0)
      {:new, s1, f1, claimed} = State.prepare(State.new(), claim)
      reservation = reserve("replay", claimed)
      {:new, s2, f2, {:committed, _, receipt}} = State.prepare(s1, reservation)
      {:ok, final} = Store.create_session(@runtime, "replay", genesis())

      {expected, frames} =
        case terminal do
          :reserved ->
            {s2, [f1, f2]}

          :created ->
            {:new, s3, f3, _} = State.prepare(s2, final)
            {s3, [f1, f2, f3]}

          :cancelled ->
            {:new, s3, f3, _} = State.prepare(s2, close(final, reservation, receipt))
            {s3, [f1, f2, f3]}
        end

      assert Enum.all?(frames, &(&1.schema_version == 2))
      assert {:ok, ^expected} = State.replay(frames)
      assert read(expected, "replay") == read(elem(State.replay(frames), 1), "replay")

      if terminal != :reserved do
        {:ok, replayed} = State.replay(frames)
        assert {:known, _} = State.prepare(replayed, final)
      end
    end
  end

  test "current replay rejects schema one missing reservation changed lineage and duplicate frames" do
    {:new, s1, f1, claimed} = State.prepare(State.new(), claim(0))
    reservation = reserve("replay", claimed)
    {:new, s2, f2, _} = State.prepare(s1, reservation)
    {:ok, final} = Store.create_session(@runtime, "replay", genesis())
    {:new, _s3, f3, _} = State.prepare(s2, final)

    for frames <- [
          [%{f1 | schema_version: 1}, f2, f3],
          [f1, f3],
          [f2, f3],
          [f1, f2, f3, f3],
          [f1, f2, %{f3 | records: []}],
          [
            f1,
            %{f2 | resolution: %{status: :not_committed, reason: :creation_domain_conflict}},
            f3
          ]
        ] do
      assert {:error, {:invalid_history, _, _}} = State.replay(frames)
    end
  end

  test "Local reopen retains cancellation and late final lookup writes no new frame" do
    with_local(fn path, pid, store ->
      claimed = Store.transact(store, claim(0))
      reservation = reserve("durable", claimed)
      {:committed, _, receipt} = Store.transact(store, reservation)
      {:ok, final} = Store.create_session(@runtime, "durable", genesis())
      {:committed, _, _} = Store.transact(store, close(final, reservation, receipt))
      before = :sys.get_state(pid).store
      assert {:ok, frames, :complete} = Loopex.Store.Local.Log.read(path)
      assert {:ok, ^before} = State.replay(frames)
      stop_joined(pid)
      bytes = File.read!(path)
      {:ok, reopened} = Loopex.Store.Local.start_link(path: path)

      try do
        {:ok, recovered} = Store.new(Loopex.Store.Local, reopened)
        assert :sys.get_state(reopened).store == before
        assert {:not_committed, :creation_cancelled} = Store.transact(recovered, final)

        assert {:ok, %{command: %{state: :not_committed, genesis: captured}}} =
                 Store.creation_recovery(recovered, %{runtime_id: @runtime, command_id: "durable"})

        assert captured == final.genesis
        assert File.read!(path) == bytes
      after
        stop_joined(reopened)
      end
    end)
  end

  test "Local process loss after close append recovers the exact cancellation binding" do
    pair = {:runtime_control_close_creation_reservation, :after_linearization_before_result}
    probe = FaultProbe.start(%{pair => [:kill]})

    try do
      with_local(fn path, pid, store ->
        :sys.replace_state(pid, &%{&1 | fault_probe: probe})
        Process.unlink(pid)
        claimed = Store.transact(store, claim(0))
        reservation = reserve("unknown-close", claimed)
        {:committed, _, receipt} = Store.transact(store, reservation)
        {:ok, final} = Store.create_session(@runtime, "unknown-close", genesis())
        closing = close(final, reservation, receipt)
        monitor = Process.monitor(pid)
        assert {:commit_unknown, id} = Store.transact(store, closing)
        assert id == closing.tx_id
        cutoff = System.monotonic_time(:millisecond) + 1_000

        assert_receive {:DOWN, ^monitor, :process, ^pid, :killed},
                       max(cutoff - System.monotonic_time(:millisecond), 0)

        {:ok, reopened} = Loopex.Store.Local.start_link(path: path, recover_stale_writer: true)

        try do
          {:ok, recovered} = Store.new(Loopex.Store.Local, reopened)
          assert {:not_committed, :creation_cancelled} = Store.transact(recovered, final)
          assert {:committed, ^id, closed} = Store.transact(recovered, closing)
          assert closed.final_resolution == {:not_committed, :creation_cancelled}
          assert FaultProbe.injected(probe) == [pair]
        after
          stop_joined(reopened)
        end
      end)
    after
      stop_probe_joined(probe)
    end
  end

  test "copying a stopped current Store log retains pending custody without dispatch" do
    with_local(fn path, pid, store ->
      claimed = Store.transact(store, claim(0))
      reservation = reserve("pending-copy", claimed)
      {:committed, _, _} = Store.transact(store, reservation)
      expected = :sys.get_state(pid).store
      stop_joined(pid)
      copy = path <> ".copy"

      try do
        File.cp!(path, copy)
        {:ok, reopened} = Loopex.Store.Local.start_link(path: copy)

        try do
          {:ok, recovered} = Store.new(Loopex.Store.Local, reopened)
          assert :sys.get_state(reopened).store == expected
          assert expected.sessions == %{}

          assert {:ok, %{command: %{state: :reserved, genesis: captured}}} =
                   Store.creation_recovery(recovered, %{runtime_id: @runtime, command_id: nil})

          assert captured == reservation.genesis
        after
          stop_joined(reopened)
        end
      after
        File.rm(copy)
        File.rm(copy <> ".writer")
      end
    end)
  end

  test "a cold VM decodes and replays created and cancelled current custody" do
    with_local(fn path, pid, store ->
      claimed = Store.transact(store, claim(0))
      first = reserve("cold-created", claimed)
      {:committed, _, _} = Store.transact(store, first)
      {:ok, final} = Store.create_session(@runtime, "cold-created", first.genesis)
      {:committed, _, _} = Store.transact(store, final)

      {:ok, %{head: head}} =
        Store.creation_recovery(store, %{runtime_id: @runtime, command_id: nil})

      {:ok, next_claim} =
        Store.claim_creation_domain(@runtime, head.owner_generation, @next_selection)

      claimed = Store.transact(store, next_claim)
      second = reserve("cold-cancelled", claimed)
      {:committed, _, receipt} = Store.transact(store, second)
      {:ok, second_final} = Store.create_session(@runtime, "cold-cancelled", second.genesis)
      {:committed, _, _} = Store.transact(store, close(second_final, second, receipt))
      stop_joined(pid)

      executable = System.find_executable("elixir") || raise "elixir executable unavailable"

      ebins =
        Enum.map([Store, Loopex.Store.Local.Log, LoopexProtocol.ToolDefinition], fn module ->
          module |> :code.which() |> List.to_string() |> Path.dirname()
        end)

      script = """
      state_module = String.to_atom("Elixir.Loopex.Store.Local.State")
      if Code.loaded?(state_module), do: System.halt(20)
      with {:ok, frames, :complete} <- Loopex.Store.Local.Log.read(#{inspect(path)}),
           true <- Enum.all?(frames, &(&1.schema_version == 2)),
           {:ok, state} <- apply(state_module, :replay, [frames]),
           {:ok, %{command: %{state: :created, final_resolution: :committed}}} <-
             apply(state_module, :creation_recovery, [state, %{runtime_id: #{inspect(@runtime)}, command_id: "cold-created"}]),
           {:ok, %{command: %{state: :not_committed, final_resolution: {:not_committed, :creation_cancelled}}}} <-
             apply(state_module, :creation_recovery, [state, %{runtime_id: #{inspect(@runtime)}, command_id: "cold-cancelled"}]) do
        IO.write("cold-custody-ok")
      else
        _ -> System.halt(21)
      end
      """

      args = ["--erl", "+S 1:1"] ++ Enum.flat_map(ebins, &["-pa", &1]) ++ ["-e", script]
      assert {"cold-custody-ok", 0} = System.cmd(executable, args, stderr_to_stdout: true)
    end)
  end

  test "creation command custody excludes resume stages and rejects their inconsistent replay" do
    for terminal <- [:reserved, :created, :cancelled] do
      {:new, s1, f1, claimed} = State.prepare(State.new(), claim(0))
      first = reserve("existing", claimed)
      {:new, s2, f2, _} = State.prepare(s1, first)
      {:ok, existing_final} = Store.create_session(@runtime, "existing", first.genesis)
      {:new, s3, f3, {:committed, _, existing}} = State.prepare(s2, existing_final)
      {:new, s4, f4, claimed} = State.prepare(s3, claim(3, @next_selection))
      reservation = reserve("occupied", claimed)
      {:new, reserved, f5, {:committed, _, receipt}} = State.prepare(s4, reservation)
      {:ok, final} = Store.create_session(@runtime, "occupied", reservation.genesis)
      closing = close(final, reservation, receipt)

      {state, frames} =
        case terminal do
          :reserved ->
            {reserved, [f1, f2, f3, f4, f5]}

          :created ->
            {:new, created, frame, _} = State.prepare(reserved, final)
            {created, [f1, f2, f3, f4, f5, frame]}

          :cancelled ->
            {:new, cancelled, frame, _} = State.prepare(reserved, closing)
            {cancelled, [f1, f2, f3, f4, f5, frame]}
        end

      {stage, candidate} = resume_stage(existing.session_id, "occupied", "collision-stage")

      {:new, refused, refusal, {:not_committed, :runtime_command_conflict}} =
        State.prepare(state, stage)

      assert refused.creation_heads == state.creation_heads
      assert refused.creation_capsules == state.creation_capsules
      assert refused.runtime_commands == state.runtime_commands
      assert {:known, {:not_committed, :runtime_command_conflict}} = State.prepare(refused, stage)
      assert {:ok, %{command: capsule}} = read(refused, "occupied")
      assert capsule.state == if(terminal == :cancelled, do: :not_committed, else: terminal)
      assert {:ok, ^refused} = State.replay(frames ++ [refusal])

      assert {:new, _unchanged_custody, _frame, {:not_committed, :runtime_command_conflict}} =
               State.prepare(refused, candidate)

      # Concept: replay cannot admit the former cross-family overwrite.
      # Technical depth: this deliberately invalid stage frame carries the
      # real constructor bytes; no final or cancellation history is invented.
      overwrite = %{
        schema_version: 2,
        transition_id: :runtime_control_stage_owner_attempt,
        transaction: stage,
        resolution: %{status: :committed, receipt: %{type: :stage_owner_attempt}},
        records: [],
        events: []
      }

      assert {:error, {:invalid_history, index, :frame_does_not_match_transition}} =
               State.replay(frames ++ [overwrite])

      assert index == length(frames)

      {other, other_candidate} =
        resume_stage(existing.session_id, "different-resume", "other-stage")

      {:new, other_state, other_frame, {:committed, stage_id, stage_receipt}} =
        State.prepare(refused, other)

      assert stage_id == other.tx_id
      assert {:known, {:committed, ^stage_id, ^stage_receipt}} = State.prepare(other_state, other)
      assert other_state.creation_heads == refused.creation_heads
      assert other_state.creation_capsules == refused.creation_capsules

      {:new, advanced, advance_frame, {:committed, advance_id, advance_receipt}} =
        State.prepare(other_state, other_candidate)

      assert advance_id == other_candidate.tx_id

      assert {:known, {:committed, ^advance_id, ^advance_receipt}} =
               State.prepare(advanced, other_candidate)

      assert advanced.creation_heads == refused.creation_heads
      assert advanced.creation_capsules == refused.creation_capsules
      assert {:ok, ^advanced} = State.replay(frames ++ [refusal, other_frame, advance_frame])

      if terminal == :reserved do
        {:new, created, create_frame, {:committed, "occupied", _}} = State.prepare(refused, final)
        assert {:ok, %{command: %{state: :created}}} = read(created, "occupied")
        assert {:ok, ^created} = State.replay(frames ++ [refusal, create_frame])
        {:new, cancelled, cancel_frame, {:committed, _, _}} = State.prepare(refused, closing)
        assert {:known, {:not_committed, :creation_cancelled}} = State.prepare(cancelled, final)
        assert {:ok, %{command: %{state: :not_committed}}} = read(cancelled, "occupied")
        assert {:ok, ^cancelled} = State.replay(frames ++ [refusal, cancel_frame])
      else
        case terminal do
          :created ->
            assert {:known, {:committed, "occupied", original}} = State.prepare(refused, final)
            assert original.session_id == capsule.session_id

          :cancelled ->
            assert {:known, {:not_committed, :creation_cancelled}} = State.prepare(refused, final)
        end
      end
    end
  end

  test "Local retains a rejected resume collision and the original reserved final across reopen" do
    with_local(fn path, pid, store ->
      claimed = Store.transact(store, claim(0))
      first = reserve("existing", claimed)
      assert {:committed, _, _} = Store.transact(store, first)
      {:ok, existing_final} = Store.create_session(@runtime, "existing", first.genesis)
      assert {:committed, _, existing} = Store.transact(store, existing_final)
      claimed = Store.transact(store, claim(3, @next_selection))
      reservation = reserve("occupied", claimed)
      assert {:committed, _, receipt} = Store.transact(store, reservation)
      {:ok, final} = Store.create_session(@runtime, "occupied", reservation.genesis)
      before = :sys.get_state(pid).store
      {stage, _candidate} = resume_stage(existing.session_id, "occupied", "durable-collision")
      assert {:not_committed, :runtime_command_conflict} = Store.transact(store, stage)
      refused = :sys.get_state(pid).store
      assert refused.creation_heads == before.creation_heads
      assert refused.creation_capsules == before.creation_capsules
      assert refused.runtime_commands == before.runtime_commands

      assert {:ok, %{command: %{state: :reserved}}} =
               Store.creation_recovery(store, %{runtime_id: @runtime, command_id: nil})

      stop_joined(pid)
      bytes = File.read!(path)
      {:ok, reopened} = Loopex.Store.Local.start_link(path: path)

      try do
        {:ok, recovered} = Store.new(Loopex.Store.Local, reopened)
        assert :sys.get_state(reopened).store == refused
        assert {:not_committed, :runtime_command_conflict} = Store.transact(recovered, stage)
        assert File.read!(path) == bytes
        assert {:committed, _, _} = Store.transact(recovered, close(final, reservation, receipt))
        assert {:not_committed, :creation_cancelled} = Store.transact(recovered, final)

        assert {:ok, %{command: %{state: :not_committed}}} =
                 Store.creation_recovery(recovered, %{
                   runtime_id: @runtime,
                   command_id: "occupied"
                 })
      after
        stop_joined(reopened)
      end
    end)
  end

  defp resume_stage(session, command, stage_id) do
    canonical =
      :erlang.term_to_binary(
        ["loopex_runtime_command_v1", @runtime, command, :resume, session, "session_journal"],
        [:deterministic]
      )

    succession_bytes =
      :erlang.term_to_binary(
        ["loopex_owner_operation_v1", @runtime, "resume", session, command],
        [:deterministic]
      )

    encoded = :crypto.hash(:sha256, succession_bytes) |> Base.encode16(case: :lower)

    owner = %{
      runtime_id: @runtime,
      command_id: command,
      command_kind: :resume,
      session_id: session,
      mutation_domain: "session_journal",
      succession_id: "succession_" <> binary_part(encoded, 0, 40),
      canonical_command_bytes: canonical,
      canonical_command_digest: :crypto.hash(:sha256, canonical),
      attempt_generation: 1
    }

    {:ok, candidate} =
      Store.advance_owner(
        session,
        "session_journal",
        "advance-" <> stage_id,
        0,
        1,
        "resume-owner",
        owner
      )

    {:ok, stage} = Store.stage_owner_attempt(owner, 0, stage_id, candidate)
    {stage, candidate}
  end

  defp with_local(fun) do
    home = System.fetch_env!("LOOPEX_HOME")
    path = Path.join(home, "creation-storage-#{System.unique_integer([:positive])}.log")
    {:ok, pid} = Loopex.Store.Local.start_link(path: path)

    try do
      {:ok, store} = Store.new(Loopex.Store.Local, pid)
      fun.(path, pid, store)
    after
      try do
        stop_joined(pid)
      after
        File.rm(path)
        File.rm(path <> ".writer")
      end
    end
  end

  defp fault_transaction(_store, :runtime_control_claim_creation_domain), do: claim(0)

  defp fault_transaction(store, :runtime_control_reserve_creation) do
    claimed = Store.transact(store, claim(0))
    reserve("fault", claimed)
  end

  defp fault_transaction(store, :runtime_control_close_creation_reservation) do
    reservation = fault_transaction(store, :runtime_control_reserve_creation)
    {:committed, _, receipt} = Store.transact(store, reservation)
    {:ok, final} = Store.create_session(@runtime, "fault", genesis())
    close(final, reservation, receipt)
  end

  defp reserved(command) do
    {state, claimed} = apply_new(State.new(), claim(0))
    reservation = reserve(command, claimed)
    {state, {:committed, _, receipt}} = apply_new(state, reservation)
    {:ok, final} = Store.create_session(@runtime, command, reservation.genesis)
    {state, final, reservation, receipt}
  end

  defp claim(generation, selection \\ @selection) do
    {:ok, transaction} = Store.claim_creation_domain(@runtime, generation, selection)
    transaction
  end

  defp reserve(command, {:committed, _, receipt}, captured \\ genesis()) do
    {:ok, transaction} =
      Store.reserve_creation(
        @runtime,
        command,
        receipt.owner_generation,
        receipt.owner_selection,
        receipt.domain_version,
        captured
      )

    transaction
  end

  defp close(final, reservation, receipt) do
    {:ok, transaction} =
      Store.close_creation_reservation(
        @runtime,
        final.command_id,
        receipt.owner_generation,
        receipt.owner_selection,
        receipt.domain_version,
        reservation.tx_id,
        receipt.reservation_domain_version,
        final
      )

    transaction
  end

  defp genesis(label \\ "original"),
    do: Loopex.ConfiguredGenesisFixture.genesis([]) |> Map.put("options", %{"label" => label})

  defp apply_new(state, transaction) do
    assert {:new, next, frame, outcome} = State.prepare(state, transaction)
    assert frame.transaction == transaction
    {next, outcome}
  end

  defp read(state, command),
    do: State.creation_recovery(state, %{runtime_id: @runtime, command_id: command})

  defp command(final) do
    bytes =
      :erlang.term_to_binary(
        ["loopex_owner_operation_v1", final.runtime_id, "create", "", final.command_id],
        [:deterministic]
      )

    encoded = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

    %{
      runtime_id: final.runtime_id,
      command_id: final.command_id,
      command_kind: :create,
      mutation_domain: "session",
      succession_id: "succession_" <> binary_part(encoded, 0, 40),
      canonical_command_bytes: final.canonical_record_bytes,
      canonical_command_digest: final.canonical_mutation_digest
    }
  end

  defp stop_joined(pid) do
    cutoff = System.monotonic_time(:millisecond) + 1_000
    monitor = Process.monitor(pid)

    try do
      if Process.alive?(pid), do: GenServer.stop(pid)
    after
      assert_receive {:DOWN, ^monitor, :process, ^pid, _},
                     max(cutoff - System.monotonic_time(:millisecond), 0)
    end
  end

  defp with_race_actor(store, kind, transaction, fun) do
    parent = self()

    {actor, monitor} =
      spawn_monitor(fn ->
        receive do
          :invoke ->
            send(parent, {:creation_race, self(), kind, Store.transact(store, transaction)})
        end
      end)

    try do
      fun.({actor, monitor})
    after
      cutoff = System.monotonic_time(:millisecond) + 1_000
      cleanup_monitor = Process.monitor(actor)
      if Process.alive?(actor), do: Process.exit(actor, :kill)

      assert_receive {:DOWN, ^cleanup_monitor, :process, ^actor, _},
                     max(cutoff - System.monotonic_time(:millisecond), 0)
    end
  end

  defp stop_probe_joined(probe) do
    cutoff = System.monotonic_time(:millisecond) + 1_000
    monitor = Process.monitor(probe)
    FaultProbe.stop(probe)

    assert_receive {:DOWN, ^monitor, :process, ^probe, _},
                   max(cutoff - System.monotonic_time(:millisecond), 0)
  end
end
