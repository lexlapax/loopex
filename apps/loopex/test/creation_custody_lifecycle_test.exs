Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/configured_genesis_helper.exs", __DIR__)
Code.require_file("support/m5_query_fault_store.exs", __DIR__)

defmodule Loopex.CreationCustodyLifecycleTest do
  use ExUnit.Case, async: false

  alias Loopex.ConfiguredGenesisFixture
  alias Loopex.M1RuntimeTestStore, as: Fixture
  alias Loopex.Runtime
  alias Loopex.Store
  alias Loopex.Store.OwnerLane

  test "held startup claim preserves status and occupies both native variants without another call" do
    {pid, store} = fixture()

    :ok =
      Fixture.hold_next_transition_before_linearization(
        pid,
        :runtime_control_claim_creation_domain,
        self()
      )

    runtime = runtime(store)

    assert_receive {:record_held_before_linearization, waiter, ^pid,
                    :runtime_control_claim_creation_domain, claim},
                   1_000

    on_exit(fn -> Fixture.release(waiter) end)
    {:ok, %{control: control}} = Runtime.children(runtime)
    state = :sys.get_state(control)
    {:ok, binding} = Store.immutable_binding(claim)
    assert state.lane.fences == %{{:runtime_control, "runtime"} => binding}
    assert state.creation.action.permitted
    assert Process.alive?(state.creation.action.worker)
    calls = Fixture.inspect_state(pid).creation_calls
    assert {:ok, %{runtime_id: "runtime"}} = Runtime.configuration(runtime)
    assert {:error, :store_unavailable} = Runtime.create_session(runtime, "native", %{})

    assert {:error, :store_unavailable} =
             Runtime.create_session_with_genesis(runtime, "complete", %{}, genesis())

    assert Fixture.inspect_state(pid).creation_calls == calls
    Fixture.release(waiter)
    ready(control)
    assert :sys.get_state(control).creation_head.owner_selection == claim.owner_selection
  end

  test "occupied Store reads refuse immediately while the actual claim call remains held" do
    {pid, store} = fixture()

    :ok =
      Fixture.hold_next_transition_before_linearization(
        pid,
        :runtime_control_claim_creation_domain,
        self()
      )

    runtime = runtime(store)
    assert_receive {:record_held_before_linearization, waiter, ^pid, _, _}, 1_000
    on_exit(fn -> Fixture.release(waiter) end)
    {:ok, %{control: control}} = Runtime.children(runtime)
    before = :sys.get_state(control)
    queries = Fixture.inspect_state(pid).creation_queries
    workers = elem(Runtime.children(runtime), 1).workers
    before_workers = Task.Supervisor.children(workers)

    for _ <- 1..8 do
      assert {:ok, :store_unavailable} = Runtime.session_existence(runtime, "session")
      assert {:ok, :store_unavailable} = Runtime.lookup_create_result(runtime, "native", %{})

      assert {:ok, :store_unavailable} =
               Runtime.lookup_create_result(runtime, "complete", %{}, genesis())

      assert {:ok, :store_unavailable} =
               Runtime.creation_provenance(runtime, %{kind: :command, command_id: "native"})

      assert {:error, :history_unavailable} = Runtime.effect_intents(runtime, "session", nil, 1)
      assert {:error, :store_unavailable} = Runtime.resume_session(runtime, "session", "resume")
    end

    after_state = :sys.get_state(control)
    assert after_state.creation == before.creation
    assert Fixture.inspect_state(pid).creation_queries == queries
    assert Task.Supervisor.children(workers) -- before_workers == []
    assert Process.alive?(before.creation.action.pid)
    Fixture.release(waiter)
    ready(control)
  end

  test "missing recovery callback leaves Control alive and no native unreserved fallback" do
    {:ok, store} = Store.new(Loopex.M5QueryFaultStore, :absent)
    runtime = runtime(store)
    {:ok, %{control: control, sessions: sessions}} = Runtime.children(runtime)
    unavailable(control)
    assert {:ok, %{runtime_id: "runtime"}} = Runtime.configuration(runtime)
    assert {:error, :store_unavailable} = Runtime.create_session(runtime, "native", %{})

    assert {:error, :store_unavailable} =
             Runtime.create_session_with_genesis(runtime, "complete", %{}, genesis())

    assert DynamicSupervisor.which_children(sessions) == []
  end

  test "two unknown presentations of one claim end the episode without a fresh candidate" do
    {pid, store} = fixture()

    Fixture.inject(pid, {:runtime_control_claim_creation_domain, :before_linearization}, 2)

    runtime = runtime(store)
    {:ok, %{control: control}} = Runtime.children(runtime)
    unavailable(control)
    calls = Fixture.inspect_state(pid).creation_calls
    assert [first, second] = calls
    assert first == second
    assert first.type == :claim_creation_domain
    assert map_size(:sys.get_state(control).lane.fences) == 1
    assert length(Fixture.inspect_state(pid).creation_queries) == 1
    assert {:error, :store_unavailable} = Runtime.create_session(runtime, "native", %{})
    assert Fixture.inspect_state(pid).creation_calls == calls
  end

  test "held reservation retains the complete prepermit fence and native repeats have no waiter" do
    {pid, store, runtime, control} = eligible()

    :ok =
      Fixture.hold_next_transition_before_linearization(
        pid,
        :runtime_control_reserve_creation,
        self()
      )

    caller = request(runtime, "native", %{"original" => "bytes"})

    assert_receive {:record_held_before_linearization, waiter, ^pid,
                    :runtime_control_reserve_creation, reserve},
                   1_000

    on_exit(fn -> Fixture.release(waiter) end)
    state = :sys.get_state(control)
    {:ok, binding} = Store.immutable_binding(reserve)
    assert state.lane.fences == %{{:runtime_control, "runtime"} => binding}
    assert state.creation.reservation == reserve
    assert state.creation.final.genesis == reserve.genesis
    calls = Fixture.inspect_state(pid).creation_calls

    assert {:error, :creation_in_progress} =
             Runtime.create_session(runtime, "native", %{"original" => "bytes"})

    assert {:error, :creation_in_progress} =
             Runtime.create_session_with_genesis(runtime, "complete", %{}, genesis())

    assert Fixture.inspect_state(pid).creation_calls == calls
    assert :sys.get_state(control).creation.from == state.creation.from
    Fixture.release(waiter)
    assert_receive {:creation_answer, ^caller, {:ok, "s_test_1"}}, 1_000
    ready(control)

    assert {:ok, {:historical, "s_test_1"}} =
             Runtime.lookup_create_result(runtime, "native", %{"original" => "bytes"})

    assert Store.immutable_binding(state.creation.final) ==
             Store.immutable_binding(
               Store.create_session("runtime", "native", reserve.genesis)
               |> elem(1)
             )

    assert store.adapter == Fixture
  end

  test "final unknown receives one exact presentation with original bytes and one cutoff" do
    {pid, _store, runtime, control} = eligible()

    :ok =
      Fixture.inject(pid, {:runtime_control_create_session, :after_linearization_before_result})

    :ok = Fixture.delay_after_commit(pid, :runtime_control_reserve_creation, self())
    caller = request(runtime, "native", %{})

    assert_receive {:transaction_linearized, waiter, ^pid, :runtime_control_reserve_creation, _},
                   1_000

    on_exit(fn -> Fixture.release(waiter) end)
    initial = :sys.get_state(control).creation
    Fixture.release(waiter)
    assert_receive {:creation_answer, ^caller, {:ok, "s_test_1"}}, 1_000
    ready(control)
    finals = Enum.filter(Fixture.inspect_state(pid).creation_calls, &(&1.type == :create_session))
    assert [first, second] = finals
    assert first == second
    assert first == initial.final
    assert initial.cutoff - System.monotonic_time(:millisecond) <= 60_000
  end

  test "caller loss after durable reserve selects close without any final dispatch" do
    {pid, _store, runtime, control} = eligible()
    :ok = Fixture.delay_after_commit(pid, :runtime_control_reserve_creation, self())
    caller = request(runtime, "native", %{"original" => "bytes"})

    assert_receive {:transaction_linearized, waiter, ^pid, :runtime_control_reserve_creation, _},
                   1_000

    on_exit(fn -> Fixture.release(waiter) end)
    original = :sys.get_state(control).creation

    :ok =
      Fixture.inject(
        pid,
        {:runtime_control_close_creation_reservation, :after_linearization_before_result}
      )

    monitors = monitor_actors(original.action)
    Process.exit(caller, :kill)
    join_actors(monitors)
    ready(control)
    state = Fixture.inspect_state(pid)

    assert [close, exact_close] =
             Enum.filter(state.creation_calls, &(&1.type == :close_creation_reservation))

    assert close == exact_close
    assert close.final_canonical_record_bytes == original.final.canonical_record_bytes
    assert close.final_canonical_mutation_digest == original.final.canonical_mutation_digest
    refute Enum.any?(state.creation_calls, &(&1.type == :create_session))
    assert state.creation_capsules[{"runtime", "native"}].state == :not_committed
    assert state.sessions == %{}

    assert {:error, :creation_cancelled} =
             Runtime.create_session(runtime, "native", %{"original" => "bytes"})

    assert {:error, :runtime_command_conflict} =
             Runtime.create_session(runtime, "native", %{"original" => "changed"})

    Fixture.release(waiter)
    assert :sys.get_state(control).creation == nil
  end

  test "caller loss after final commit returns historical creation without activating it" do
    {pid, _store, runtime, control} = eligible()
    :ok = Fixture.delay_after_commit(pid, :runtime_control_create_session, self())
    caller = request(runtime, "native", %{})

    assert_receive {:transaction_linearized, waiter, ^pid, :runtime_control_create_session,
                    {:committed, "native", _}},
                   1_000

    on_exit(fn -> Fixture.release(waiter) end)
    original = :sys.get_state(control).creation
    monitors = monitor_actors(original.action)
    Process.exit(caller, :kill)
    join_actors(monitors)
    ready(control)
    assert Fixture.inspect_state(pid).sessions["s_test_1"].owner_epoch == 0
    assert :sys.get_state(control).sessions == %{}
    assert {:ok, "s_test_1"} = Runtime.create_session(runtime, "native", %{})
    assert :sys.get_state(control).sessions == %{}
    Fixture.release(waiter)
  end

  test "unlinearized reserve after caller loss remains deliverable and successor closes its original capture" do
    {pid, _store, runtime, control} = eligible()

    :ok =
      Fixture.hold_next_transition_before_linearization(
        pid,
        :runtime_control_reserve_creation,
        self()
      )

    caller = request(runtime, "native", %{})

    assert_receive {:record_held_before_linearization, waiter, ^pid,
                    :runtime_control_reserve_creation, reserve},
                   1_000

    on_exit(fn -> Fixture.release(waiter) end)
    original = :sys.get_state(control).creation
    monitors = monitor_actors(original.action)
    Process.exit(caller, :kill)
    join_actors(monitors)
    unavailable(control)
    assert Map.has_key?(:sys.get_state(control).lane.fences, {:runtime_control, "runtime"})
    # Original actor joins did not retract the Store's held delivery.
    Fixture.release(waiter)

    await(fn ->
      Map.has_key?(Fixture.inspect_state(pid).creation_capsules, {"runtime", "native"})
    end)

    assert :ok = Runtime.stop(runtime)
    replacement = runtime(elem(Store.new(Fixture, pid), 1))
    {:ok, %{control: successor}} = Runtime.children(replacement)
    ready(successor)
    state = Fixture.inspect_state(pid)
    capsule = state.creation_capsules[{"runtime", "native"}]
    assert capsule.genesis == reserve.genesis
    assert capsule.state == :not_committed
    refute state.creation_heads["runtime"].owner_selection == reserve.owner_selection
    assert {:error, :creation_cancelled} = Runtime.create_session(replacement, "native", %{})
    assert state.sessions == %{}
  end

  test "successor claim wins before held old reservation and permanently makes its delivery stale" do
    {pid, store, runtime, control} = eligible()

    :ok =
      Fixture.hold_next_transition_before_linearization(
        pid,
        :runtime_control_reserve_creation,
        self()
      )

    caller = request(runtime, "native", %{})

    assert_receive {:record_held_before_linearization, waiter, ^pid,
                    :runtime_control_reserve_creation, old},
                   1_000

    on_exit(fn -> Fixture.release(waiter) end)
    original = :sys.get_state(control).creation
    monitors = monitor_actors(original.action)
    Process.exit(caller, :kill)
    join_actors(monitors)
    unavailable(control)
    assert :ok = Runtime.stop(runtime)
    replacement = runtime(store)
    {:ok, %{control: successor}} = Runtime.children(replacement)
    ready(successor)
    Fixture.release(waiter)

    await(fn ->
      Map.has_key?(
        Fixture.inspect_state(pid).creation_resolutions,
        {"runtime", :reserve_creation, old.tx_id}
      )
    end)

    assert Fixture.inspect_state(pid).creation_capsules == %{}

    assert Fixture.inspect_state(pid).creation_resolutions[
             {"runtime", :reserve_creation, old.tx_id}
           ].outcome ==
             {:not_committed, :stale_creation_generation}

    assert {:ok, "s_test_1"} = Runtime.create_session(replacement, "native", %{})

    new_reserve =
      Fixture.inspect_state(pid).creation_calls
      |> Enum.filter(&(&1.type == :reserve_creation))
      |> List.last()

    refute new_reserve.tx_id == old.tx_id
  end

  test "Control failure joins the original carrier and fresh startup never activates committed history" do
    {pid, _store, runtime, control} = eligible()
    :ok = Fixture.delay_after_commit(pid, :runtime_control_create_session, self())
    caller = request(runtime, "native", %{})

    assert_receive {:transaction_linearized, waiter, ^pid, :runtime_control_create_session, _},
                   1_000

    on_exit(fn -> Fixture.release(waiter) end)
    state = :sys.get_state(control)
    monitors = monitor_actors(state.creation.action)
    old_selection = state.creation_selection
    Process.exit(control, :kill)
    join_actors(monitors)
    assert_receive {:creation_answer, ^caller, {:error, :runtime_unavailable}}, 1_000

    successor =
      await_value(fn ->
        case Runtime.children(runtime) do
          {:ok, %{control: next}} when next != control -> next
          _ -> nil
        end
      end)

    ready(successor)
    refute :sys.get_state(successor).creation_selection == old_selection
    assert {:ok, "s_test_1"} = Runtime.create_session(runtime, "native", %{})
    assert :sys.get_state(successor).sessions == %{}
    assert Fixture.inspect_state(pid).sessions["s_test_1"].owner_epoch == 0
    Fixture.release(waiter)
  end

  test "carrier loss after commit retains original joins and close resolves history without activation" do
    {pid, _store, runtime, control} = eligible()
    :ok = Fixture.delay_after_commit(pid, :runtime_control_create_session, self())
    caller = request(runtime, "native", %{})

    assert_receive {:transaction_linearized, waiter, ^pid, :runtime_control_create_session, _},
                   1_000

    on_exit(fn -> Fixture.release(waiter) end)
    original = :sys.get_state(control).creation
    monitors = monitor_actors(original.action)
    Process.exit(original.action.pid, :kill)
    join_actors(monitors)
    assert_receive {:creation_answer, ^caller, {:ok, "s_test_1"}}, 1_000
    ready(control)
    assert :sys.get_state(control).sessions == %{}
    assert Fixture.inspect_state(pid).sessions["s_test_1"].owner_epoch == 0
    Fixture.release(waiter)
  end

  test "wrong incarnation and original permit cannot replace a held real outcome" do
    {pid, _store, runtime, control} = eligible()
    :ok = Fixture.delay_after_commit(pid, :runtime_control_reserve_creation, self())
    caller = request(runtime, "native", %{})

    assert_receive {:transaction_linearized, waiter, ^pid, :runtime_control_reserve_creation,
                    outcome},
                   1_000

    on_exit(fn -> Fixture.release(waiter) end)
    state = :sys.get_state(control)
    entry = state.creation
    action = entry.action

    for {incarnation, invocation, permit, guardian} <- [
          {make_ref(), entry.invocation, action.permit, action.pid},
          {state.creation_incarnation, make_ref(), action.permit, action.pid},
          {state.creation_incarnation, entry.invocation, make_ref(), action.pid},
          {state.creation_incarnation, entry.invocation, action.permit, self()}
        ] do
      send(
        control,
        {:creation_carrier_joined, incarnation, invocation, permit, guardian, action.group,
         action.worker, outcome}
      )
    end

    assert :sys.get_state(control).creation == entry
    assert :sys.get_state(control).lane == state.lane
    Fixture.release(waiter)
    assert_receive {:creation_answer, ^caller, {:ok, "s_test_1"}}, 1_000
    ready(control)

    send(
      control,
      {:creation_carrier_joined, state.creation_incarnation, entry.invocation, action.permit,
       action.pid, action.group, action.worker, outcome}
    )

    assert :sys.get_state(control).creation == nil
  end

  test "runtime stop remains serviceable during an actual held Store RPC and joins owned actors" do
    {pid, _store, runtime, control} = eligible()

    :ok =
      Fixture.hold_next_transition_before_linearization(
        pid,
        :runtime_control_reserve_creation,
        self()
      )

    caller = request(runtime, "native", %{})
    assert_receive {:record_held_before_linearization, waiter, ^pid, _, _}, 1_000
    on_exit(fn -> Fixture.release(waiter) end)
    monitors = monitor_actors(:sys.get_state(control).creation.action)
    assert {:ok, %{runtime_id: "runtime"}} = Runtime.configuration(runtime)
    assert :ok = Runtime.stop(runtime)
    join_actors(monitors)
    assert_receive {:creation_answer, ^caller, {:error, :runtime_unavailable}}, 1_000
    refute Runtime.alive?(runtime)
    # Store remains the owner of its deliverable, independent of the runtime join.
    refute :sys.get_state(pid).pending_transactions == %{}
    Fixture.release(waiter)
  end

  test "one runtime mutation fence covers claim reserve F and close and retains changed-byte refusal" do
    {_pid, store} = fixture()
    {:ok, claim} = Store.claim_creation_domain("runtime", 0, String.duplicate("a", 64))

    {:ok, reserve} =
      Store.reserve_creation("runtime", "native", 1, String.duplicate("a", 64), 0, genesis())

    {:ok, final} = Store.create_session("runtime", "native", reserve.genesis)

    {:ok, close} =
      Store.close_creation_reservation(
        "runtime",
        "native",
        2,
        String.duplicate("a", 64),
        1,
        reserve.tx_id,
        1,
        final
      )

    lane = OwnerLane.new(store)
    {:ok, binding, claimed} = OwnerLane.admit(lane, claim)
    assert claimed.fences == %{{:runtime_control, "runtime"} => binding}
    assert {:error, {:fenced, :commit_unknown}, ^claimed} = OwnerLane.admit(claimed, reserve)
    resolved = OwnerLane.observe(claimed, claim, {:not_committed, :stale_creation_generation})
    {:ok, _, reserved} = OwnerLane.admit(resolved, reserve)
    assert {:error, {:fenced, :commit_unknown}, ^reserved} = OwnerLane.admit(reserved, final)
    {:ok, close_binding, closing} = OwnerLane.admit_creation_close(reserved, close, final)
    assert closing.fences == %{{:runtime_control, "runtime"} => close_binding}
    assert {:error, {:fenced, :commit_unknown}, ^closing} = OwnerLane.admit(closing, final)
    changed = %{final | canonical_record_bytes: final.canonical_record_bytes <> <<0>>}
    assert {:error, _, _} = OwnerLane.admit_creation_close(reserved, close, changed)
    assert OwnerLane.observe(closing, close, {:commit_unknown, close.tx_id}) == closing
    assert OwnerLane.observe(closing, final, {:not_committed, :creation_cancelled}) == closing
    restored = OwnerLane.observe(closing, close, {:not_committed, :creation_domain_conflict})
    {:ok, reserve_binding} = Store.immutable_binding(reserve)
    assert restored.fences == %{{:runtime_control, "runtime"} => reserve_binding}
    assert restored.creation_prior == %{}
    assert {:committed, _, _} = Store.transact(store, claim)
    assert {:committed, _, _} = Store.transact(store, reserve)

    assert {:committed, _, %{final_resolution: {:not_committed, :creation_cancelled}}} =
             terminal = Store.transact(store, close)

    assert OwnerLane.observe(closing, close, terminal).fences == %{}
  end

  test "one terminal stale claim permits only a current-head reread and second fresh CAS" do
    {pid, store} = fixture()

    :ok =
      Fixture.hold_next_transition_before_linearization(
        pid,
        :runtime_control_claim_creation_domain,
        self()
      )

    runtime = runtime(store)
    assert_receive {:record_held_before_linearization, waiter, ^pid, _, first}, 1_000
    on_exit(fn -> Fixture.release(waiter) end)
    {:ok, rival} = Store.claim_creation_domain("runtime", 0, String.duplicate("b", 64))
    assert {:committed, _, _} = Store.transact(store, rival)
    Fixture.release(waiter)
    {:ok, %{control: control}} = Runtime.children(runtime)
    ready(control)

    own =
      Enum.filter(
        Fixture.inspect_state(pid).creation_calls,
        &(&1.owner_selection == first.owner_selection)
      )

    assert [^first, second] = own
    assert second.expected_owner_generation == 1
    assert second.tx_id != first.tx_id
    assert length(Fixture.inspect_state(pid).creation_queries) == 3
    assert :sys.get_state(control).creation_head.owner_generation == 2
  end

  test "retained successful claim receipt cannot grant authority after a later selection" do
    {pid, store} = fixture()
    :ok = Fixture.delay_after_commit(pid, :runtime_control_claim_creation_domain, self())
    runtime = runtime(store)
    assert_receive {:transaction_linearized, waiter, ^pid, _, _}, 1_000
    on_exit(fn -> Fixture.release(waiter) end)
    {:ok, rival} = Store.claim_creation_domain("runtime", 1, String.duplicate("b", 64))
    assert {:committed, _, _} = Store.transact(store, rival)
    Fixture.release(waiter)
    {:ok, %{control: control}} = Runtime.children(runtime)
    unavailable(control)
    assert {:error, :store_unavailable} = Runtime.create_session(runtime, "native", %{})
    refute Enum.any?(Fixture.inspect_state(pid).creation_calls, &(&1.type == :reserve_creation))
  end

  test "occupied provider proof refuses without a read and postcommit retains the complete spend" do
    {pid, store, runtime, control} = eligible()
    assert {:ok, session} = Runtime.create_session(runtime, "existing", %{})
    ready(control)
    active = :sys.get_state(control).sessions[session]
    # This controlled native cut makes the test process the current intake caller.
    # The owner and both attempt-open rows remain actual committed Store evidence.
    coordinator = self()

    :sys.replace_state(control, fn state ->
      %{state | sessions: Map.put(state.sessions, session, %{active | coordinator: coordinator})}
    end)

    opened = fn operation ->
      %{
        "run_id" => "run",
        "turn_id" => "turn",
        "operation_id" => operation,
        "attempt" => 1,
        "staged_request_digest" => String.duplicate("a", 64),
        :kind => "model_attempt_opened_v1"
      }
    end

    commit = fn operation, version ->
      record = opened.(operation)

      {:ok, tx} =
        Store.session_commit(
          session,
          "session",
          "open-" <> operation,
          active.owner.owner_epoch,
          active.owner.owner_incarnation_id,
          version,
          [record],
          []
        )

      {:committed, _, receipt} = Store.transact(store, tx)
      next = receipt.journal_versions.last

      assert :ok =
               Loopex.Runtime.Control.post_commit(
                 control,
                 session,
                 active.owner,
                 %{journal_version: next, event_sequence: active.event_sequence},
                 receipt
               )

      {:ok, binding} = Loopex.Runtime.ProviderAttempt.binding_from_opened(session, record)
      {next, binding}
    end

    {version, first} = commit.("first", active.journal_version)
    reference = make_ref()

    authority = %{
      coordinator: self(),
      owner: active.owner,
      runtime_id: "runtime",
      worker: self(),
      permit_reference: reference,
      deadline: System.system_time(:millisecond) + 60_000,
      journal_version: version,
      attempt_open_version: version
    }

    assert {:ok, :dispatched} =
             Loopex.Runtime.Control.provider_dispatch(control, first, authority)

    assert_receive {:loopex_provider_permit, ^reference, ^first}, 1_000

    :ok =
      Fixture.hold_next_transition_before_linearization(
        pid,
        :runtime_control_reserve_creation,
        self()
      )

    caller = request(runtime, "other", %{})
    assert_receive {:record_held_before_linearization, waiter, ^pid, _, _}, 1_000
    on_exit(fn -> Fixture.release(waiter) end)
    before_reads = Fixture.inspect_state(pid).record_reads
    spent = :sys.get_state(control).spent_attempts
    {next_version, second} = commit.("second", version)
    assert :sys.get_state(control).spent_attempts == spent
    assert Fixture.inspect_state(pid).record_reads == before_reads
    next_reference = make_ref()

    authority = %{
      authority
      | permit_reference: next_reference,
        journal_version: next_version,
        attempt_open_version: next_version
    }

    assert {:error, :invalid_provider_attempt_binding} =
             Loopex.Runtime.Control.provider_dispatch(control, second, authority)

    refute_received {:loopex_provider_permit, ^next_reference, _}
    assert :sys.get_state(control).spent_attempts == spent
    assert Fixture.inspect_state(pid).record_reads == before_reads
    Fixture.release(waiter)
    assert_receive {:creation_answer, ^caller, {:ok, _}}, 1_000
    ready(control)

    assert {:ok, :dispatched} =
             Loopex.Runtime.Control.provider_dispatch(control, second, authority)

    assert_receive {:loopex_provider_permit, ^next_reference, ^second}, 1_000
    assert length(Fixture.inspect_state(pid).record_reads) > length(before_reads)
  end

  test "complete genesis and implicit historical replay retain original capture under changed defaults" do
    {pid, _store, runtime, control} = eligible()
    options = %{"original" => "complete"}
    complete = Map.put(genesis(), "options", options)

    assert {:ok, session} =
             Runtime.create_session_with_genesis(runtime, "complete", options, complete)

    ready(control)
    before_calls = Fixture.inspect_state(pid).creation_calls

    changed =
      ConfiguredGenesisFixture.genesis(
        [],
        ConfiguredGenesisFixture.configuration("Changed host instructions.")
      )

    :sys.replace_state(control, fn state ->
      %{state | session_creation_defaults: Map.drop(changed, [:kind, "options"])}
    end)

    assert {:ok, ^session} = Runtime.create_session(runtime, "complete", options)

    assert {:ok, ^session} =
             Runtime.create_session_with_genesis(runtime, "complete", options, complete)

    assert {:error, :runtime_command_conflict} =
             Runtime.create_session_with_genesis(
               runtime,
               "complete",
               options,
               Map.put(changed, "options", options)
             )

    assert Fixture.inspect_state(pid).creation_calls == before_calls

    retained =
      Fixture.inspect_state(pid).sessions[session].records |> hd() |> Map.fetch!(:payload)

    {:ok, final} = Store.create_session("runtime", "complete", complete)
    assert retained == final.genesis
  end

  test "owned carrier before permit dispatches nothing and its positive exact permit makes one call" do
    {pid, store} = fixture()
    {:ok, workers} = Task.Supervisor.start_link()
    # Concept: The linked fixture supervisor may exit before its on_exit callback stops it.
    # Technical depth: Accept only absence of this original supervisor; other stop failures surface.
    on_exit(fn ->
      try do
        if Process.alive?(workers), do: Supervisor.stop(workers)
      catch
        :exit, {:noproc, {GenServer, :stop, [^workers, :normal, :infinity]}} -> :ok
      end
    end)

    {:ok, claim} = Store.claim_creation_domain("runtime", 0, String.duplicate("a", 64))
    incarnation = make_ref()
    invocation = make_ref()
    permit = make_ref()
    cutoff = System.monotonic_time(:millisecond) + 60_000

    {:ok, guardian} =
      Loopex.Runtime.CreationCarrier.start(
        workers,
        self(),
        incarnation,
        invocation,
        permit,
        store,
        {:transaction, claim},
        cutoff,
        5_000,
        nil
      )

    guardian_monitor = Process.monitor(guardian)
    send(guardian, {:creation_guard_owned, self(), incarnation, invocation, permit})

    assert_receive {:creation_carrier_ready, ^incarnation, ^invocation, ^permit, ^guardian, group,
                    worker},
                   1_000

    group_monitor = Process.monitor(group)
    worker_monitor = Process.monitor(worker)
    Process.exit(guardian, :kill)
    join_actors([{guardian, guardian_monitor}, {group, group_monitor}, {worker, worker_monitor}])
    assert Fixture.inspect_state(pid).creation_calls == []
    invocation = make_ref()
    permit = make_ref()

    {:ok, guardian} =
      Loopex.Runtime.CreationCarrier.start(
        workers,
        self(),
        incarnation,
        invocation,
        permit,
        store,
        {:transaction, claim},
        cutoff,
        5_000,
        nil
      )

    guardian_monitor = Process.monitor(guardian)
    send(guardian, {:creation_guard_owned, self(), incarnation, invocation, permit})

    assert_receive {:creation_carrier_ready, ^incarnation, ^invocation, ^permit, ^guardian, group,
                    worker},
                   1_000

    group_monitor = Process.monitor(group)
    worker_monitor = Process.monitor(worker)
    send(worker, {:creation_permit, self(), make_ref(), invocation, permit})
    assert Fixture.inspect_state(pid).creation_calls == []
    send(worker, {:creation_permit, self(), incarnation, invocation, permit})

    assert_receive {:creation_carrier_joined, ^incarnation, ^invocation, ^permit, ^guardian,
                    ^group, ^worker, {:committed, _, _}},
                   1_000

    join_actors([{guardian, guardian_monitor}, {group, group_monitor}, {worker, worker_monitor}])
    assert Fixture.inspect_state(pid).creation_calls == [claim]
  end

  test "original post-terminal read queued before the timer cannot reopen expired cleanup" do
    {pid, _store, runtime, control} = eligible()
    :ok = Fixture.delay_after_commit(pid, :runtime_control_create_session, self())
    caller = request(runtime, "late-read", %{})

    assert_receive {:transaction_linearized, final_waiter, ^pid, :runtime_control_create_session,
                    _},
                   1_000

    on_exit(fn -> Fixture.release(final_waiter) end)
    final_action = :sys.get_state(control).creation.action
    final_monitors = monitor_actors(final_action)
    :ok = Fixture.hold_next_creation_recovery(pid, self())
    Process.exit(caller, :kill)
    join_actors(final_monitors)

    assert_receive {:creation_read_held, before_close_waiter, _, %{command_id: "late-read"}},
                   1_000

    on_exit(fn -> Fixture.release(before_close_waiter) end)
    assert :sys.get_state(control).creation.phase == :before_close
    :ok = Fixture.hold_next_creation_recovery(pid, self())
    Fixture.release(before_close_waiter)

    assert_receive {:creation_read_held, terminal_waiter, reader, %{command_id: "late-read"}},
                   1_000

    on_exit(fn -> Fixture.release(terminal_waiter) end)
    original = :sys.get_state(control)
    assert original.creation.phase == :post_terminal
    assert original.creation.action.worker == reader
    assert original.creation.terminal == {:ok, "s_test_1"}
    assert original.cleanup_grace_ms == 5_000
    assert original.creation.cleanup.observe - original.creation.cleanup.cooperative == 5_000
    assert Fixture.inspect_state(pid).sessions["s_test_1"].owner_epoch == 0
    calls = Fixture.inspect_state(pid).creation_calls
    queries = Fixture.inspect_state(pid).creation_queries
    expire_after_original_join(control, terminal_waiter, original.creation)
    assert_expired_original_creation(runtime, control, original, calls, queries, pid)

    assert {:ok, %{command: %{state: :created, session_id: "s_test_1"}}} =
             :sys.get_state(control).creation.action.joined

    assert :sys.get_state(control).lane == original.lane
    Fixture.release(final_waiter)
  end

  test "original committed close queued before the timer retains its full fence after cleanup expiry" do
    {pid, _store, runtime, control} = eligible()
    :ok = Fixture.delay_after_commit(pid, :runtime_control_reserve_creation, self())
    :ok = Fixture.delay_after_commit(pid, :runtime_control_close_creation_reservation, self())
    caller = request(runtime, "late-close", %{})

    assert_receive {:transaction_linearized, reserve_waiter, ^pid,
                    :runtime_control_reserve_creation, _},
                   1_000

    on_exit(fn -> Fixture.release(reserve_waiter) end)
    reserve_monitors = monitor_actors(:sys.get_state(control).creation.action)
    Process.exit(caller, :kill)
    join_actors(reserve_monitors)

    assert_receive {:transaction_linearized, close_waiter, ^pid,
                    :runtime_control_close_creation_reservation,
                    {:committed, _, %{final_resolution: {:not_committed, :creation_cancelled}}}},
                   1_000

    on_exit(fn -> Fixture.release(close_waiter) end)
    original = :sys.get_state(control)
    assert original.creation.phase == :close
    assert original.creation.action.permitted
    close = original.creation.transaction
    {:ok, binding} = Store.immutable_binding(close)
    assert original.lane.fences == %{{:runtime_control, "runtime"} => binding}
    assert map_size(original.lane.creation_prior) == 1
    assert original.cleanup_grace_ms == 5_000
    assert original.creation.cleanup.observe - original.creation.cleanup.cooperative == 5_000

    assert Fixture.inspect_state(pid).creation_capsules[{"runtime", "late-close"}].state ==
             :not_committed

    calls = Fixture.inspect_state(pid).creation_calls
    queries = Fixture.inspect_state(pid).creation_queries
    expire_after_original_join(control, close_waiter, original.creation)
    assert_expired_original_creation(runtime, control, original, calls, queries, pid)

    assert {:committed, close_tx_id, %{final_resolution: {:not_committed, :creation_cancelled}}} =
             :sys.get_state(control).creation.action.joined

    assert close_tx_id == close.tx_id
    assert :sys.get_state(control).lane == original.lane
    assert Fixture.inspect_state(pid).sessions == %{}
    Fixture.release(reserve_waiter)
  end

  # Concept: real Store results and physical joins can await Control past its cutoff.
  # Technical depth: suspend only serial observation, retaining the original
  # 10,000-ms cleanup period, original actors and actual Store delivery. No
  # injected receipt, deadline replacement or synthetic DOWN participates.
  defp expire_after_original_join(control, waiter, entry) do
    assert entry.cleanup.observe - (entry.cleanup.cooperative - 5_000) == 10_000
    monitors = monitor_actors(entry.action)
    on_exit(fn -> resume_creation_control(control) end)

    try do
      assert System.monotonic_time(:millisecond) < entry.cleanup.observe
      :ok = :sys.suspend(control)
      Fixture.release(waiter)
      join_actors(monitors)
      invocation = entry.invocation
      permit = entry.action.permit
      guardian = entry.action.pid
      group = entry.action.group
      worker = entry.action.worker
      {:messages, queued} = Process.info(control, :messages)

      assert Enum.any?(queued, fn
               {:creation_carrier_joined, _, ^invocation, ^permit, ^guardian, ^group, ^worker, _} ->
                 true

               _ ->
                 false
             end)

      for {actor, monitor} <- [
            {guardian, entry.action.monitor},
            {group, entry.action.group_monitor},
            {worker, entry.action.worker_monitor}
          ] do
        assert Enum.any?(queued, fn
                 {:DOWN, ^monitor, :process, ^actor, _} -> true
                 _ -> false
               end)
      end

      refute Enum.any?(queued, fn
               {:creation_cleanup_expired, _, ^invocation} -> true
               _ -> false
             end)

      assert System.monotonic_time(:millisecond) < entry.cleanup.observe
      remaining = max(entry.cleanup.observe + 1 - System.monotonic_time(:millisecond), 0)

      receive do
      after
        remaining -> :ok
      end

      assert System.monotonic_time(:millisecond) >= entry.cleanup.observe + 1
    after
      try do
        Fixture.release(waiter)
      after
        resume_creation_control(control)
      end
    end
  end

  defp resume_creation_control(control) do
    try do
      :sys.resume(control)
    catch
      :exit, _ -> :ok
    end
  end

  defp assert_expired_original_creation(runtime, control, original, calls, queries, pid) do
    await(fn ->
      state = :sys.get_state(control)
      entry = state.creation

      is_map(entry) and entry.cleanup_unproved and entry.action.worker_down and
        entry.action.group_down and entry.action.guardian_down
    end)

    state = :sys.get_state(control)
    assert state.creation_status == :unavailable
    assert state.creation.from == nil
    assert state.creation.invocation == original.creation.invocation
    assert state.creation.cutoff == original.creation.cutoff
    assert state.creation.cleanup == original.creation.cleanup
    assert state.creation.action.pid == original.creation.action.pid
    assert state.creation.action.group == original.creation.action.group
    assert state.creation.action.worker == original.creation.action.worker

    actor_binding = [
      :pid,
      :monitor,
      :group,
      :group_monitor,
      :worker,
      :worker_monitor,
      :permit,
      :operation,
      :permitted
    ]

    assert Map.take(state.creation.action, actor_binding) ==
             Map.take(original.creation.action, actor_binding)

    assert state.sessions == %{}
    {:ok, %{sessions: sessions, workers: workers}} = Runtime.children(runtime)
    assert DynamicSupervisor.which_children(sessions) == []
    assert Task.Supervisor.children(workers) == []
    assert {:error, :creation_in_progress} = Runtime.create_session(runtime, "after-expiry", %{})

    assert {:error, :creation_in_progress} =
             Runtime.create_session_with_genesis(runtime, "after-expiry-complete", %{}, genesis())

    assert :sys.get_state(control).creation == state.creation
    assert Fixture.inspect_state(pid).creation_calls == calls
    assert Fixture.inspect_state(pid).creation_queries == queries
  end

  defp fixture do
    {pid, store} = Fixture.start_store()
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {pid, store}
  end

  defp runtime(store) do
    {:ok, runtime} =
      Loopex.start_link(
        runtime_id: "runtime",
        context_token_budget: 8_192,
        store: store,
        session_creation_defaults: Map.drop(genesis(), [:kind, "options"]),
        cleanup_grace_ms: 5_000
      )

    on_exit(fn -> if Runtime.alive?(runtime), do: Runtime.stop(runtime) end)
    runtime
  end

  defp eligible do
    {pid, store} = fixture()
    runtime = runtime(store)
    {:ok, %{control: control}} = Runtime.children(runtime)
    ready(control)
    {pid, store, runtime, control}
  end

  defp genesis, do: ConfiguredGenesisFixture.genesis([])

  defp request(runtime, command, options) do
    observer = self()

    caller =
      spawn(fn ->
        send(
          observer,
          {:creation_answer, self(), Runtime.create_session(runtime, command, options)}
        )
      end)

    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
    caller
  end

  defp ready(control),
    do:
      await(fn ->
        state = :sys.get_state(control)
        state.creation_status == :ready and is_nil(state.creation)
      end)

  defp unavailable(control),
    do:
      await(fn ->
        state = :sys.get_state(control)
        state.creation_status == :unavailable and is_nil(state.creation)
      end)

  defp monitor_actors(action),
    do:
      for(
        pid <- [action.pid, action.group, action.worker],
        do: {pid, Process.monitor(pid)}
      )

  defp join_actors(monitors) do
    for {pid, monitor} <- monitors,
        do: assert_receive({:DOWN, ^monitor, :process, ^pid, _}, 1_000)
  end

  defp await(check), do: await_value(fn -> if check.(), do: true end)
  defp await_value(check), do: await_value(check, System.monotonic_time(:millisecond) + 1_000)

  defp await_value(check, cutoff) do
    case check.() do
      nil ->
        assert System.monotonic_time(:millisecond) < cutoff

        receive do
        after
          1 -> :ok
        end

        await_value(check, cutoff)

      false ->
        assert System.monotonic_time(:millisecond) < cutoff

        receive do
        after
          1 -> :ok
        end

        await_value(check, cutoff)

      value ->
        value
    end
  end
end
