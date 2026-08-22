defmodule LoopexStoreLocalTest.FaultProbe do
  @moduledoc false

  def start(overrides \\ %{}) when is_map(overrides) do
    spawn(fn -> loop(overrides, [], []) end)
  end

  def checkpoint(nil, _pair), do: :continue

  def checkpoint(probe, pair) when is_pid(probe) do
    reference = make_ref()
    send(probe, {:loopex_store_fault_point, self(), reference, pair})

    receive do
      {:loopex_store_fault_action, ^reference, action} -> action
    after
      5_000 -> {:error, :fault_probe_timeout}
    end
  end

  def observed(probe) do
    reference = make_ref()
    send(probe, {:report, self(), reference})

    receive do
      {^reference, pairs} -> pairs
    after
      2_000 -> raise "fault probe did not report"
    end
  end

  def injected(probe) do
    reference = make_ref()
    send(probe, {:injected, self(), reference})

    receive do
      {^reference, pairs} -> pairs
    after
      2_000 -> raise "fault probe did not report injections"
    end
  end

  def stop(probe), do: send(probe, :stop)

  defp loop(overrides, observed, injected) do
    receive do
      {:loopex_store_fault_point, store, reference, pair} ->
        {action, next_overrides} = take_action(overrides, pair)
        send(store, {:loopex_store_fault_action, reference, action})
        next_injected = if action == :continue, do: injected, else: [pair | injected]
        loop(next_overrides, [pair | observed], next_injected)

      {:report, caller, reference} ->
        send(caller, {reference, Enum.reverse(observed)})
        loop(overrides, observed, injected)

      {:injected, caller, reference} ->
        send(caller, {reference, Enum.reverse(injected)})
        loop(overrides, observed, injected)

      :stop ->
        :ok
    end
  end

  defp take_action(overrides, pair) do
    case Map.get(overrides, pair, []) do
      [action | rest] -> {action, Map.put(overrides, pair, rest)}
      action when action in [:continue, :return_unknown, :kill] -> {action, overrides}
      [] -> {:continue, overrides}
    end
  end
end

defmodule LoopexStoreLocalTest.Memory do
  @moduledoc false

  use GenServer

  @behaviour Loopex.Store

  alias Loopex.Store
  alias Loopex.Store.Local.State
  alias Loopex.Store.Transitions
  alias LoopexStoreLocalTest.FaultProbe

  def start_link(options \\ []), do: GenServer.start_link(__MODULE__, options)

  @impl Store
  def transact(reference, transaction), do: GenServer.call(reference, {:transact, transaction})

  @impl Store
  def transaction_status(reference, session_id, mutation_domain, tx_id) do
    GenServer.call(reference, {:transaction_status, session_id, mutation_domain, tx_id})
  end

  @impl Store
  def ownership_head(reference, session_id, mutation_domain) do
    GenServer.call(reference, {:ownership_head, session_id, mutation_domain})
  end

  @impl Store
  def load_records(reference, session_id, after_version, limit) do
    GenServer.call(reference, {:load_records, session_id, after_version, limit})
  end

  @impl Store
  def load_events(reference, session_id, after_sequence, limit) do
    GenServer.call(reference, {:load_events, session_id, after_sequence, limit})
  end

  @impl GenServer
  def init(options), do: {:ok, %{store: State.new(), fault_probe: options[:fault_probe]}}

  @impl GenServer
  def handle_call({:transact, transaction}, _from, state) do
    case State.prepare(state.store, transaction) do
      {:known, outcome} ->
        with {:ok, transition} <- Transitions.id(transaction),
             :continue <-
               FaultProbe.checkpoint(
                 state.fault_probe,
                 {transition, :recovery_representation}
               ) do
          {:reply, outcome, state}
        else
          :return_unknown -> {:reply, unknown(transaction), state}
          _other -> {:stop, :fault_probe_refused, unknown(transaction), state}
        end

      {:invalid, outcome} ->
        {:reply, outcome, state}

      {:new, next, _frame, outcome} ->
        {:ok, transition} = Transitions.id(transaction)

        case FaultProbe.checkpoint(state.fault_probe, {transition, :before_linearization}) do
          :continue ->
            committed = %{state | store: next}

            case FaultProbe.checkpoint(
                   state.fault_probe,
                   {transition, :after_linearization_before_result}
                 ) do
              :continue -> {:reply, outcome, committed}
              :return_unknown -> {:reply, unknown(transaction), committed}
              :kill -> Process.exit(self(), :kill)
              _other -> {:stop, :fault_probe_refused, unknown(transaction), committed}
            end

          :return_unknown ->
            {:reply, unknown(transaction), state}

          :kill ->
            Process.exit(self(), :kill)

          _other ->
            {:stop, :fault_probe_refused, unknown(transaction), state}
        end
    end
  end

  def handle_call(
        {:transaction_status, session_id, mutation_domain, tx_id},
        _from,
        state
      ) do
    {:reply, State.transaction_status(state.store, session_id, mutation_domain, tx_id), state}
  end

  def handle_call({:ownership_head, session_id, _mutation_domain}, _from, state) do
    {:reply, State.ownership_head(state.store, session_id), state}
  end

  def handle_call({:load_records, session_id, after_version, limit}, _from, state) do
    {:reply, State.load_records(state.store, session_id, after_version, limit), state}
  end

  def handle_call({:load_events, session_id, after_sequence, limit}, _from, state) do
    {:reply, State.load_events(state.store, session_id, after_sequence, limit), state}
  end

  defp unknown(transaction) do
    {:ok, tx_id} = Store.transaction_id(transaction)
    {:commit_unknown, tx_id}
  end
end

defmodule LoopexStoreLocalTest.Conformance do
  @moduledoc false

  import ExUnit.Assertions

  alias Loopex.Store
  alias Loopex.Store.Local
  alias Loopex.Store.Local.Log
  alias Loopex.Store.OwnerLane
  alias Loopex.Store.Transitions
  alias LoopexStoreLocalTest.FaultProbe
  alias LoopexStoreLocalTest.Memory

  @domain "session_journal"

  def atomic_fencing do
    each_store(fn context ->
      owned = create_owned(context, unique("atomic"), "owner-a")

      first = commit_tx(owned, "commit-a", owned.journal_version, "fact-a", "event-a")

      assert {:committed, "commit-a", first_receipt} = Store.transact(context.store, first)
      assert first_receipt.journal_versions == %{first: 3, last: 3}

      {:ok, successor} =
        Store.advance_owner(
          owned.session_id,
          @domain,
          "owner-b-tx",
          1,
          3,
          "owner-b"
        )

      assert {:committed, "owner-b-tx", successor_receipt} =
               Store.transact(context.store, successor)

      assert successor_receipt.owner_epoch == 2
      assert successor_receipt.journal_version == 4

      stale_epoch =
        commit_tx(
          %{owned | owner_epoch: 1, owner_id: "owner-a", journal_version: 4},
          "stale-epoch",
          4,
          "never",
          "never-e"
        )

      assert {:not_committed, :stale_owner_epoch} = Store.transact(context.store, stale_epoch)

      wrong_incarnation =
        commit_tx(
          %{owned | owner_epoch: 2, owner_id: "wrong-owner", journal_version: 4},
          "wrong-incarnation",
          4,
          "never",
          "never-i"
        )

      assert {:not_committed, :stale_owner_incarnation_id} =
               Store.transact(context.store, wrong_incarnation)

      wrong_incarnation_and_version =
        commit_tx(
          %{owned | owner_epoch: 2, owner_id: "wrong-owner", journal_version: 4},
          "wrong-incarnation-and-version",
          3,
          "never",
          "never-iv"
        )

      assert {:not_committed, :stale_owner_incarnation_id} =
               Store.transact(context.store, wrong_incarnation_and_version)

      stale_version =
        commit_tx(
          %{owned | owner_epoch: 2, owner_id: "owner-b", journal_version: 4},
          "stale-version",
          3,
          "never",
          "never-v"
        )

      assert {:not_committed, :stale_journal_version} =
               Store.transact(context.store, stale_version)

      all_wrong =
        commit_tx(
          %{owned | owner_epoch: 0, owner_id: "wrong", journal_version: 4},
          "all-wrong",
          0,
          "never",
          "never-all"
        )

      assert {:not_committed, :stale_owner_epoch} = Store.transact(context.store, all_wrong)

      assert {:committed, "commit-a", ^first_receipt} = Store.transact(context.store, first)
      assert {:ok, records} = Store.load_records(context.store, owned.session_id, 0, 100)
      assert Enum.map(records, & &1.journal_version) == [1, 2, 3, 4]

      assert Store.transaction_status(
               context.store,
               owned.session_id,
               @domain,
               "stale-epoch"
             ) == {:terminal, {:not_committed, :stale_owner_epoch}}

      assert {:ok, head} = Store.ownership_head(context.store, owned.session_id, @domain)
      assert head == %{owner_epoch: 2, journal_version: 4}

      assert_one_successor(context)
      assert_same_tx_successor_conflict(context)
      assert_head_cas_race(context)
      assert_succession_recovery_orders(context)
      assert_non_commit_succession_binding_conflicts(context)
    end)

    assert_local_writer_exclusion()
  end

  def killed_writer_and_fault_catalogue do
    each_store_with_unknown(fn context ->
      owned = create_owned(context, unique("unknown"), "owner-u")
      transaction = commit_tx(owned, "unknown-tx", 2, "unknown-fact", "unknown-event")
      owner = OwnerLane.new(context.store)

      assert {{:commit_unknown, "unknown-tx"}, fenced_owner} =
               OwnerLane.transact(owner, transaction)

      bypass = commit_tx(owned, "unknown-bypass", 2, "bypass", "bypass-event")

      assert {{:fenced, :commit_unknown}, ^fenced_owner} =
               OwnerLane.transact(fenced_owner, bypass)

      assert :absent =
               Store.transaction_status(
                 context.store,
                 owned.session_id,
                 @domain,
                 "unknown-bypass"
               )

      assert {{:committed, "unknown-tx", _receipt}, resolved_owner} =
               OwnerLane.transact(fenced_owner, transaction)

      refute OwnerLane.fenced?(resolved_owner, transaction)

      assert {:ok, records} = Store.load_records(context.store, owned.session_id, 0, 100)
      assert Enum.count(records, &(&1.payload[:kind] == "fact")) == 1

      assert {:ok, events} = Store.load_events(context.store, owned.session_id, 0, 100)
      assert Enum.map(events, &{&1.event_id, &1.event_sequence}) == [{"unknown-event", 1}]
    end)

    assert_interrupted_non_commit()
    local_kill_after_commit()
    assert_complete_fault_catalogue()
    assert_derived_fault_injection()
  end

  def replay_audit do
    context = start_store(:local)

    try do
      owned = create_owned(context, unique("replay"), "owner-old")
      transaction = commit_tx(owned, "replay-commit", 2, "durable", "replay-event")
      assert {:committed, "replay-commit", _receipt} = Store.transact(context.store, transaction)

      {:ok, successor} =
        Store.advance_owner(owned.session_id, @domain, "replay-owner-new", 1, 3, "owner-new")

      assert {:committed, "replay-owner-new", _receipt} =
               Store.transact(context.store, successor)

      stop(context.pid)
      restarted = restart_local(context)

      assert {:committed, "replay-owner-new", historical} =
               Store.transact(restarted.store, successor)

      assert historical.owner_incarnation_id == "owner-new"

      {:ok, latest_owner} =
        Store.advance_owner(
          owned.session_id,
          @domain,
          "replay-owner-latest",
          2,
          4,
          "owner-latest"
        )

      assert {:committed, "replay-owner-latest", latest_receipt} =
               Store.transact(restarted.store, latest_owner)

      assert {:committed, "replay-owner-new", ^historical} =
               Store.transact(restarted.store, successor)

      superseded_new =
        commit_tx(
          %{owned | owner_epoch: 2, owner_id: "owner-new", journal_version: 5},
          "replay-superseded-new",
          5,
          "never",
          "never-new"
        )

      assert {:not_committed, :stale_owner_epoch} =
               Store.transact(restarted.store, superseded_new)

      stale =
        commit_tx(
          %{owned | owner_epoch: 1, owner_id: "owner-old", journal_version: 4},
          "replay-stale",
          4,
          "never",
          "never-replay"
        )

      assert {:not_committed, :stale_owner_epoch} = Store.transact(restarted.store, stale)

      {:ok, malicious} =
        Store.session_commit(
          owned.session_id,
          @domain,
          "replay-malicious",
          1,
          "owner-old",
          5,
          [%{kind: :fact, value: "illegal-stale-commit"}],
          [%{event_id: "illegal-stale-event", kind: :fact_committed}]
        )

      stop(restarted.pid)

      append_fencing_bypass(
        restarted.path,
        malicious,
        latest_receipt.owner_epoch,
        latest_receipt.owner_incarnation_id,
        1
      )

      assert {:error, {:invalid_history, _index, :frame_does_not_match_transition}} =
               Local.start_link(path: restarted.path, recover_stale_writer: true)
    after
      close(context)
    end

    assert_physical_corruption_visible()
    assert_replay_mutation_corpus()
  end

  def retained_resolutions do
    assert %{
             state: :redacted_store_state,
             message: :redacted_store_message,
             log: [],
             reason: :redacted_store_reason
           } =
             Local.format_status(%{
               state: %{owner_incarnation_id: "secret"},
               message: {:transact, %{owner_incarnation_id: "secret"}},
               log: [{:in, %{owner_incarnation_id: "secret"}}],
               reason: {:failure, %{owner_incarnation_id: "secret"}}
             })

    dynamic_atom = String.to_atom("loopex_cold_atom_#{unique("kind")}")
    dynamic_name = Atom.to_string(dynamic_atom)

    assert {:ok, normalized} =
             Store.create_session("runtime", "normalized", %{
               dynamic_atom => "plain",
               kind: dynamic_atom
             })

    assert normalized.genesis == %{dynamic_name => "plain", kind: dynamic_name}

    for reserved <- [
          :event_sequence,
          :owner_epoch,
          :owner_incarnation_id,
          "event_sequence",
          "owner_epoch",
          "owner_incarnation_id"
        ] do
      event =
        Map.put(
          %{event_id: "event", kind: :fact_committed},
          reserved,
          "must-not-be-public"
        )

      assert {:error, :invalid_events} =
               Store.session_commit(
                 "session",
                 @domain,
                 "reserved-event",
                 0,
                 "owner",
                 0,
                 [%{kind: :fact}],
                 [event]
               )
    end

    assert {:error, :invalid_events} =
             Store.session_commit(
               "session",
               @domain,
               "nested-reserved-event",
               0,
               "owner",
               0,
               [%{kind: :fact}],
               [
                 %{
                   event_id: "event",
                   kind: :fact_committed,
                   payload: %{owner_incarnation_id: "not-public"}
                 }
               ]
             )

    assert {:error, :owner_capability_in_public_event} =
             Store.session_commit(
               "session",
               @domain,
               "nested-owner-capability",
               0,
               "owner-secret",
               0,
               [%{kind: :fact}],
               [
                 %{
                   event_id: "event",
                   kind: :fact_committed,
                   payload: %{safe: ["prefix-owner-secret-suffix"]}
                 }
               ]
             )

    {:ok, safe_transaction} =
      Store.session_commit(
        "session",
        @domain,
        "forged-event",
        0,
        "owner-secret",
        0,
        [%{kind: :fact}],
        [%{event_id: "event", kind: :fact_committed, payload: %{"safe" => "value"}}]
      )

    forged_reserved =
      safe_transaction
      |> put_in([:outbox, Access.at(0), "payload"], %{
        "owner_incarnation_id" => "not-public"
      })
      |> rebind_session_transaction()

    assert {:error, :invalid_events} = Store.validate_transaction(forged_reserved)

    forged_capability =
      safe_transaction
      |> put_in([:outbox, Access.at(0), "payload"], %{
        "safe" => ["prefix-owner-secret-suffix"]
      })
      |> rebind_session_transaction()

    assert {:error, :owner_capability_in_public_event} =
             Store.validate_transaction(forged_capability)

    assert {:error, :invalid_records} =
             Store.session_commit(
               "session",
               @domain,
               "runtime-term",
               0,
               "owner",
               0,
               [%{kind: :fact, process: self()}],
               []
             )

    for incarnation <- [self(), make_ref(), fn -> :runtime_term end, :atom] do
      assert {:error, :invalid_identifier} =
               Store.advance_owner("session", @domain, "advance", 0, 0, incarnation)

      assert {:error, :invalid_identifier} =
               Store.session_commit(
                 "session",
                 @domain,
                 "commit",
                 0,
                 incarnation,
                 0,
                 [%{kind: :fact}],
                 []
               )
    end

    each_store(fn context ->
      label = unique("retained")
      {:ok, create} = Store.create_session("runtime-#{label}", "create-#{label}", genesis(label))

      assert {:committed, _tx, create_receipt} = Store.transact(context.store, create)
      assert {:committed, _tx, ^create_receipt} = Store.transact(context.store, create)

      {:ok, changed_create} =
        Store.create_session("runtime-#{label}", "create-#{label}", %{
          kind: :session_genesis,
          label: "changed"
        })

      assert {:not_committed, :tx_id_conflict} =
               Store.transact(context.store, changed_create)

      {:ok, owner} =
        Store.advance_owner(
          create_receipt.session_id,
          @domain,
          "owner-#{label}",
          0,
          1,
          "owner-#{label}"
        )

      assert {:committed, _tx, owner_receipt} = Store.transact(context.store, owner)
      assert {:committed, _tx, ^owner_receipt} = Store.transact(context.store, owner)

      assert {:terminal, :committed} =
               Store.transaction_status(
                 context.store,
                 create_receipt.session_id,
                 @domain,
                 "owner-#{label}"
               )

      owned = %{
        session_id: create_receipt.session_id,
        owner_epoch: 1,
        owner_id: "owner-#{label}",
        journal_version: 2
      }

      transaction = commit_tx(owned, "known-#{label}", 2, "known", "known-event-#{label}")
      assert {:committed, _tx, commit_receipt} = Store.transact(context.store, transaction)
      assert {:committed, _tx, ^commit_receipt} = Store.transact(context.store, transaction)

      assert {:terminal, :committed} =
               Store.transaction_status(
                 context.store,
                 owned.session_id,
                 @domain,
                 transaction.tx_id
               )

      assert_binding_conflicts(context, transaction)

      {:ok, changed} =
        Store.session_commit(
          owned.session_id,
          @domain,
          transaction.tx_id,
          1,
          owned.owner_id,
          2,
          [%{kind: :fact, value: "different"}],
          [%{event_id: "different-event-#{label}", kind: :fact_committed}]
        )

      same_digest_collision = %{
        changed
        | canonical_mutation_digest: transaction.canonical_mutation_digest
      }

      assert {:not_committed, :tx_id_conflict} =
               Store.transact(context.store, same_digest_collision)

      assert {:not_committed, :tx_id_conflict} =
               Store.transact(context.store, Map.put(transaction, :extra, self()))

      duplicate_event =
        commit_tx(
          %{owned | journal_version: 3},
          "duplicate-event-#{label}",
          3,
          "never",
          "known-event-#{label}"
        )

      assert {:not_committed, :duplicate_event_id} =
               Store.transact(context.store, duplicate_event)

      assert {:terminal, {:not_committed, :duplicate_event_id}} =
               Store.transaction_status(
                 context.store,
                 owned.session_id,
                 @domain,
                 duplicate_event.tx_id
               )

      bad_version =
        commit_tx(
          %{owned | journal_version: 3},
          "bad-version-#{label}",
          99,
          "never",
          "bad-event-#{label}"
        )

      assert {:not_committed, :stale_journal_version} =
               Store.transact(context.store, bad_version)

      assert {:not_committed, :stale_journal_version} =
               Store.transact(context.store, bad_version)

      assert {:terminal, {:not_committed, :stale_journal_version}} =
               Store.transaction_status(
                 context.store,
                 owned.session_id,
                 @domain,
                 bad_version.tx_id
               )

      assert_binding_conflicts(context, bad_version)

      changed_bad_version = %{bad_version | expected_journal_version: 3}

      assert {:not_committed, :tx_id_conflict} =
               Store.transact(context.store, changed_bad_version)

      assert :absent =
               Store.transaction_status(context.store, owned.session_id, @domain, "absent")

      {:ok, other_domain} =
        Store.session_commit(
          owned.session_id,
          "other-domain",
          transaction.tx_id,
          1,
          owned.owner_id,
          3,
          [%{kind: :fact, value: "other-domain"}],
          [%{event_id: "other-domain-event-#{label}", kind: :fact_committed}]
        )

      assert {:committed, _tx, _receipt} = Store.transact(context.store, other_domain)

      assert {:terminal, :committed} =
               Store.transaction_status(
                 context.store,
                 owned.session_id,
                 "other-domain",
                 transaction.tx_id
               )

      other_owned = create_owned(context, unique("scope-session"), "scope-owner")

      other_session =
        commit_tx(other_owned, transaction.tx_id, 2, "other-session", unique("event"))

      assert {:committed, _tx, _receipt} = Store.transact(context.store, other_session)

      assert {:terminal, :committed} =
               Store.transaction_status(
                 context.store,
                 other_owned.session_id,
                 @domain,
                 transaction.tx_id
               )

      missing_session = unique("missing-session")

      {:ok, absent_session_transaction} =
        Store.session_commit(
          missing_session,
          @domain,
          "missing-tx-#{label}",
          0,
          "missing-owner",
          0,
          [%{kind: :fact, value: "never"}],
          []
        )

      assert {:not_committed, :session_not_found} =
               Store.transact(context.store, absent_session_transaction)

      assert {:terminal, {:not_committed, :session_not_found}} =
               Store.transaction_status(
                 context.store,
                 missing_session,
                 @domain,
                 absent_session_transaction.tx_id
               )

      assert {:not_committed, :session_not_found} =
               Store.transact(context.store, absent_session_transaction)

      assert {:ok, records} = Store.load_records(context.store, owned.session_id, 0, 100)
      assert Enum.map(records, & &1.journal_version) == [1, 2, 3, 4]

      assert {:ok, events} = Store.load_events(context.store, owned.session_id, 0, 100)

      assert Enum.map(events, & &1.event_id) == [
               "known-event-#{label}",
               "other-domain-event-#{label}"
             ]
    end)

    assert_terminal_status_recovery()
    assert_durable_resolution_replay()
    assert_status_unavailable()
  end

  def durable_restart do
    context = start_store(:local)

    try do
      owned = create_owned(context, unique("durable"), "owner-durable")
      cold_atom = String.to_atom("loopex_cold_frame_atom_#{unique("payload")}")
      cold_name = Atom.to_string(cold_atom)

      {:ok, transaction} =
        Store.session_commit(
          owned.session_id,
          @domain,
          "multi-record",
          1,
          "owner-durable",
          2,
          [
            %{cold_atom => "one", kind: cold_atom},
            %{kind: :fact, value: "two"}
          ],
          [
            %{event_id: "event-one", kind: :fact_committed, value: "one"},
            %{event_id: "event-two", kind: :fact_committed, value: "two"}
          ]
        )

      assert {:committed, "multi-record", receipt} = Store.transact(context.store, transaction)
      assert receipt.journal_versions == %{first: 3, last: 4}
      assert receipt.event_sequences == %{first: 1, last: 2}

      kill(context.pid)
      assert_cold_vm_replay(context.path)
      restarted = restart_local(context)

      assert {:ok, records} = Store.load_records(restarted.store, owned.session_id, 0, 100)
      assert Enum.map(records, & &1.journal_version) == [1, 2, 3, 4]
      assert Enum.at(records, 2).payload == %{cold_name => "one", kind: cold_name}

      assert Enum.map(records, & &1.owner_epoch) == [0, 1, 1, 1]

      assert Enum.map(records, & &1.owner_incarnation_id) == [
               nil,
               "owner-durable",
               "owner-durable",
               "owner-durable"
             ]

      assert {:ok, events} = Store.load_events(restarted.store, owned.session_id, 0, 100)
      assert Enum.map(events, & &1.event_sequence) == [1, 2]
      assert Enum.map(events, & &1.event_id) == ["event-one", "event-two"]

      assert Enum.all?(events, fn event ->
               not Map.has_key?(event, :owner_incarnation_id) and
                 not Map.has_key?(event, :owner_epoch)
             end)

      stop(restarted.pid)
      File.write!(restarted.path, <<"LX">>, [:append, :binary])

      torn_bytes = File.read!(restarted.path)

      assert {:ok, _frames, {:torn, offset, observed_size, observed_digest}} =
               Log.read(restarted.path)

      File.write!(restarted.path, "S", [:append, :binary])

      assert {:error, :store_changed_during_repair} =
               Log.repair_torn_tail(
                 restarted.path,
                 offset,
                 observed_size,
                 observed_digest
               )

      assert File.read!(restarted.path) == torn_bytes <> "S"
      File.write!(restarted.path, torn_bytes, [:binary])

      repaired = restart_local(restarted)

      assert {:ok, repaired_records} =
               Store.load_records(repaired.store, owned.session_id, 0, 100)

      assert repaired_records == records

      next_owned = %{owned | journal_version: 4}
      after_repair = commit_tx(next_owned, "after-repair", 4, "three", "event-three")
      assert {:committed, "after-repair", _receipt} = Store.transact(repaired.store, after_repair)

      kill(repaired.pid)
      final = restart_local(repaired)
      assert {:ok, final_records} = Store.load_records(final.store, owned.session_id, 0, 100)
      assert Enum.map(final_records, & &1.journal_version) == [1, 2, 3, 4, 5]
      stop(final.pid)
    after
      close(context)
    end
  end

  defp each_store(fun) do
    for kind <- [:memory, :local] do
      context = start_store(kind)

      try do
        fun.(context)
      after
        close(context)
      end
    end
  end

  defp each_store_with_unknown(fun) do
    pair = {:session_journal_commit, :after_linearization_before_result}

    for kind <- [:memory, :local] do
      probe = FaultProbe.start(%{pair => [:return_unknown]})
      context = start_store(kind, probe)

      try do
        fun.(context)
      after
        close(context)
        FaultProbe.stop(probe)
      end
    end
  end

  defp start_store(kind, probe \\ nil)

  defp start_store(:memory, probe) do
    {:ok, pid} = Memory.start_link(fault_probe: probe)
    {:ok, store} = Store.new(Memory, pid)
    %{kind: :memory, pid: pid, store: store, path: nil}
  end

  defp start_store(:local, probe) do
    path = store_path()
    {:ok, pid} = Local.start_link(path: path, fault_probe: probe)
    {:ok, store} = Store.new(Local, pid)
    %{kind: :local, pid: pid, store: store, path: path}
  end

  defp create_owned(context, label, owner_id) do
    {:ok, create} = Store.create_session("runtime-#{label}", "create-#{label}", genesis(label))
    assert {:committed, _tx, create_receipt} = Store.transact(context.store, create)

    {:ok, advance} =
      Store.advance_owner(
        create_receipt.session_id,
        @domain,
        "advance-#{label}",
        0,
        1,
        owner_id
      )

    assert {:committed, _tx, advance_receipt} = Store.transact(context.store, advance)

    %{
      session_id: create_receipt.session_id,
      owner_epoch: advance_receipt.owner_epoch,
      owner_id: advance_receipt.owner_incarnation_id,
      journal_version: advance_receipt.journal_version
    }
  end

  defp commit_tx(owned, tx_id, expected_version, fact, event_id) do
    {:ok, transaction} =
      Store.session_commit(
        owned.session_id,
        @domain,
        tx_id,
        owned.owner_epoch,
        owned.owner_id,
        expected_version,
        [%{kind: :fact, value: fact}],
        [%{event_id: event_id, kind: :fact_committed, value: fact}]
      )

    transaction
  end

  defp assert_one_successor(context) do
    owned = create_owned(context, unique("successor"), "successor-base")

    {:ok, first} =
      Store.advance_owner(owned.session_id, @domain, unique("successor-a"), 1, 2, "successor-a")

    {:ok, second} =
      Store.advance_owner(owned.session_id, @domain, unique("successor-b"), 1, 2, "successor-b")

    results =
      [first, second]
      |> Enum.map(&Task.async(fn -> Store.transact(context.store, &1) end))
      |> Enum.map(&Task.await(&1, 5_000))

    assert Enum.count(results, &match?({:committed, _, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:not_committed, :stale_owner_epoch})) == 1
  end

  defp assert_same_tx_successor_conflict(context) do
    owned = create_owned(context, unique("same-tx"), "same-base")
    tx_id = unique("same-successor-tx")

    {:ok, first} =
      Store.advance_owner(owned.session_id, @domain, tx_id, 1, 2, "same-successor-a")

    {:ok, second} =
      Store.advance_owner(owned.session_id, @domain, tx_id, 1, 2, "same-successor-b")

    results =
      [first, second]
      |> Enum.map(&Task.async(fn -> Store.transact(context.store, &1) end))
      |> Enum.map(&Task.await(&1, 5_000))

    assert Enum.count(results, &match?({:committed, _, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:not_committed, :tx_id_conflict})) == 1
  end

  defp assert_head_cas_race(context) do
    owned = create_owned(context, unique("head-race"), "head-race-base")
    assert {:ok, head} = Store.ownership_head(context.store, owned.session_id, @domain)

    {:ok, intervening} =
      Store.advance_owner(
        owned.session_id,
        @domain,
        unique("intervening"),
        head.owner_epoch,
        head.journal_version,
        "intervening-owner"
      )

    assert {:committed, _tx_id, _receipt} = Store.transact(context.store, intervening)

    {:ok, stale_cas} =
      Store.advance_owner(
        owned.session_id,
        @domain,
        unique("stale-cas"),
        head.owner_epoch,
        head.journal_version,
        "stale-cas-owner"
      )

    assert {:not_committed, :stale_owner_epoch} =
             Store.transact(context.store, stale_cas)
  end

  defp assert_succession_recovery_orders(context) do
    for order <- [:original_first, :recovery_first] do
      owned = create_owned(context, unique("recovery-order"), "recovery-order-base")
      original_id = unique("original-succession")

      assert :absent =
               Store.transaction_status(context.store, owned.session_id, @domain, original_id)

      assert {:ok, head} = Store.ownership_head(context.store, owned.session_id, @domain)

      {:ok, original} =
        Store.advance_owner(
          owned.session_id,
          @domain,
          original_id,
          head.owner_epoch,
          head.journal_version,
          "original-owner"
        )

      {:ok, recovery} =
        Store.advance_owner(
          owned.session_id,
          @domain,
          unique("recovery-succession"),
          head.owner_epoch,
          head.journal_version,
          "recovery-owner"
        )

      {winner, loser} =
        case order do
          :original_first -> {original, recovery}
          :recovery_first -> {recovery, original}
        end

      assert {:committed, _tx_id, _receipt} = Store.transact(context.store, winner)
      assert {:not_committed, :stale_owner_epoch} = Store.transact(context.store, loser)
    end
  end

  defp assert_non_commit_succession_binding_conflicts(context) do
    owned = create_owned(context, unique("succession-binding"), "succession-binding-owner")

    {:ok, winner} =
      Store.advance_owner(
        owned.session_id,
        @domain,
        unique("succession-binding-winner"),
        owned.owner_epoch,
        owned.journal_version,
        "succession-binding-current"
      )

    assert {:committed, _tx_id, _receipt} = Store.transact(context.store, winner)

    {:ok, refused} =
      Store.advance_owner(
        owned.session_id,
        @domain,
        unique("succession-binding-refused"),
        owned.owner_epoch,
        owned.journal_version,
        "succession-binding-loser"
      )

    assert {:not_committed, :stale_owner_epoch} = Store.transact(context.store, refused)
    assert {:not_committed, :stale_owner_epoch} = Store.transact(context.store, refused)

    assert {:terminal, {:not_committed, :stale_owner_epoch}} =
             Store.transaction_status(
               context.store,
               owned.session_id,
               @domain,
               refused.tx_id
             )

    conflicting = [
      %{refused | expected_owner_epoch: refused.expected_owner_epoch + 1},
      %{refused | expected_journal_version: refused.expected_journal_version + 1},
      %{
        refused
        | proposed_owner_incarnation_id: refused.proposed_owner_incarnation_id <> "-changed"
      },
      %{refused | canonical_mutation_digest: <<0::256>>},
      %{refused | canonical_record_bytes: refused.canonical_record_bytes <> <<0>>}
    ]

    for transaction <- conflicting do
      assert {:not_committed, :tx_id_conflict} =
               Store.transact(context.store, transaction)
    end
  end

  defp assert_local_writer_exclusion do
    context = start_store(:local)

    try do
      owned = create_owned(context, unique("writer-lock"), "writer-lock-owner")

      assert {:error, {:store_writer_active, writer_path}} =
               Local.start_link(path: context.path)

      assert writer_path == context.path <> ".writer"

      alias_path = context.path <> ".hardlink"
      :ok = File.ln(context.path, alias_path)

      assert {:error, {:store_file_aliased, ^alias_path}} =
               Local.start_link(path: alias_path)

      :ok = File.rm(alias_path)
      kill(context.pid)
      restarted = restart_local(context)
      assert {:ok, _head} = Store.ownership_head(restarted.store, owned.session_id, @domain)
      stop(restarted.pid)
    after
      close(context)
    end
  end

  defp local_kill_after_commit do
    pair = {:session_journal_commit, :after_linearization_before_result}
    probe = FaultProbe.start(%{pair => [:continue, :kill]})
    context = start_store(:local, probe)

    try do
      owned = create_owned(context, unique("kill"), "owner-kill")
      acknowledged = commit_tx(owned, "acknowledged", 2, "ack", "ack-event")
      assert {:committed, "acknowledged", _receipt} = Store.transact(context.store, acknowledged)

      ambiguous_owned = %{owned | journal_version: 3}
      ambiguous = commit_tx(ambiguous_owned, "ambiguous", 3, "maybe", "maybe-event")
      assert {:commit_unknown, "ambiguous"} = Store.transact(context.store, ambiguous)
      refute Process.alive?(context.pid)

      restarted = restart_local(context)
      assert {:committed, "ambiguous", _receipt} = Store.transact(restarted.store, ambiguous)

      assert {:ok, records} = Store.load_records(restarted.store, owned.session_id, 0, 100)

      assert Enum.map(records, & &1.payload["value"]) |> Enum.reject(&is_nil/1) == [
               "ack",
               "maybe"
             ]

      assert {:ok, events} = Store.load_events(restarted.store, owned.session_id, 0, 100)

      assert Enum.map(events, &{&1.event_id, &1.event_sequence}) == [
               {"ack-event", 1},
               {"maybe-event", 2}
             ]

      stop(restarted.pid)
    after
      close(context)
      FaultProbe.stop(probe)
    end
  end

  defp assert_interrupted_non_commit do
    pair = {:session_journal_commit, :after_linearization_before_result}

    for kind <- [:memory, :local] do
      probe = FaultProbe.start(%{pair => [:return_unknown]})
      context = start_store(kind, probe)

      try do
        owned = create_owned(context, unique("unknown-refusal"), "refused-owner")

        {:ok, successor} =
          Store.advance_owner(
            owned.session_id,
            @domain,
            unique("refusal-successor"),
            1,
            2,
            "refusal-successor"
          )

        assert {:committed, _tx_id, _receipt} = Store.transact(context.store, successor)

        refused =
          commit_tx(
            %{owned | journal_version: 3},
            "ambiguous-refusal",
            3,
            "never",
            "never-event"
          )

        owner = OwnerLane.new(context.store)

        assert {{:commit_unknown, "ambiguous-refusal"}, fenced} =
                 OwnerLane.transact(owner, refused)

        bypass = %{refused | tx_id: "ambiguous-refusal-bypass"}
        assert {{:fenced, :commit_unknown}, ^fenced} = OwnerLane.transact(fenced, bypass)

        assert {{:not_committed, :stale_owner_epoch}, resolved} =
                 OwnerLane.transact(fenced, refused)

        refute OwnerLane.fenced?(resolved, refused)

        assert {:terminal, {:not_committed, :stale_owner_epoch}} =
                 Store.transaction_status(
                   context.store,
                   owned.session_id,
                   @domain,
                   refused.tx_id
                 )

        assert {:ok, []} = Store.load_events(context.store, owned.session_id, 0, 100)

        if kind == :local do
          stop(context.pid)
          restarted = restart_local(context)

          assert {:not_committed, :stale_owner_epoch} =
                   Store.transact(restarted.store, refused)

          assert {:ok, []} = Store.load_events(restarted.store, owned.session_id, 0, 100)
          stop(restarted.pid)
        end
      after
        close(context)
        FaultProbe.stop(probe)
      end
    end
  end

  defp assert_complete_fault_catalogue do
    probe = FaultProbe.start()
    context = start_store(:local, probe)

    try do
      label = unique("catalogue")
      {:ok, create} = Store.create_session("runtime-#{label}", "create-#{label}", genesis(label))
      assert {:committed, _tx, create_receipt} = Store.transact(context.store, create)
      assert {:committed, _tx, _receipt} = Store.transact(context.store, create)

      {:ok, advance} =
        Store.advance_owner(
          create_receipt.session_id,
          @domain,
          "advance-#{label}",
          0,
          1,
          "owner-#{label}"
        )

      assert {:committed, _tx, advance_receipt} = Store.transact(context.store, advance)
      assert {:committed, _tx, _receipt} = Store.transact(context.store, advance)

      owned = %{
        session_id: create_receipt.session_id,
        owner_epoch: advance_receipt.owner_epoch,
        owner_id: advance_receipt.owner_incarnation_id,
        journal_version: advance_receipt.journal_version
      }

      commit = commit_tx(owned, "catalogue-commit", 2, "catalogue", "catalogue-event")
      assert {:committed, _tx, _receipt} = Store.transact(context.store, commit)
      assert {:committed, _tx, _receipt} = Store.transact(context.store, commit)

      observed = FaultProbe.observed(probe) |> MapSet.new()
      declared = Transitions.declared_pairs() |> MapSet.new()

      assert observed == declared
      assert length(FaultProbe.observed(probe)) == MapSet.size(declared)
      assert FaultProbe.injected(probe) == []

      assert {:error, :unknown_fault_point} =
               Transitions.validate_pair(:unknown, :before_linearization)

      assert {:error, :unknown_fault_point} =
               Transitions.validate_pair(:session_journal_commit, :unknown)
    after
      close(context)
      FaultProbe.stop(probe)
    end
  end

  defp assert_derived_fault_injection do
    injected =
      for kind <- [:memory, :local],
          pair <- Transitions.declared_pairs(),
          reduce: [] do
        pairs -> inject_fault_pair(kind, pair) ++ pairs
      end

    declared_twice =
      Transitions.declared_pairs()
      |> Enum.flat_map(fn pair -> [pair, pair] end)
      |> Enum.sort()

    assert MapSet.new(injected) == MapSet.new(Transitions.declared_pairs())
    assert Enum.sort(injected) == declared_twice
  end

  defp inject_fault_pair(kind, {transition, phase} = pair) do
    probe = FaultProbe.start(%{pair => [:return_unknown]})
    context = start_store(kind, probe)

    try do
      transaction = fault_target(context, transition, unique("fault"))
      tx_id = transaction_tx_id(transaction)
      owner = OwnerLane.new(context.store)

      case phase do
        :before_linearization ->
          assert {{:commit_unknown, ^tx_id}, fenced} = OwnerLane.transact(owner, transaction)
          assert OwnerLane.fenced?(fenced, transaction)

          assert {{:committed, ^tx_id, _receipt}, resolved} =
                   OwnerLane.transact(fenced, transaction)

          refute OwnerLane.fenced?(resolved, transaction)

        :after_linearization_before_result ->
          assert {{:commit_unknown, ^tx_id}, fenced} = OwnerLane.transact(owner, transaction)
          assert OwnerLane.fenced?(fenced, transaction)

          assert {{:committed, ^tx_id, _receipt}, resolved} =
                   OwnerLane.transact(fenced, transaction)

          refute OwnerLane.fenced?(resolved, transaction)

        :recovery_representation ->
          assert {{:committed, ^tx_id, receipt}, current} =
                   OwnerLane.transact(owner, transaction)

          assert {{:commit_unknown, ^tx_id}, fenced} =
                   OwnerLane.transact(current, transaction)

          assert {{:committed, ^tx_id, ^receipt}, resolved} =
                   OwnerLane.transact(fenced, transaction)

          refute OwnerLane.fenced?(resolved, transaction)
      end

      assert FaultProbe.injected(probe) == [pair]
      [pair]
    after
      close(context)
      FaultProbe.stop(probe)
    end
  end

  defp fault_target(_context, :runtime_control_create_session, label) do
    {:ok, transaction} =
      Store.create_session("runtime-#{label}", "create-#{label}", genesis(label))

    transaction
  end

  defp fault_target(context, :session_journal_advance_owner, label) do
    {:ok, create} = Store.create_session("runtime-#{label}", "create-#{label}", genesis(label))
    assert {:committed, _tx_id, receipt} = Store.transact(context.store, create)

    {:ok, transaction} =
      Store.advance_owner(receipt.session_id, @domain, "advance-#{label}", 0, 1, "owner-#{label}")

    transaction
  end

  defp fault_target(context, :session_journal_commit, label) do
    owned = create_owned(context, label, "owner-#{label}")
    commit_tx(owned, "commit-#{label}", 2, "fact", "event-#{label}")
  end

  defp transaction_tx_id(%{type: :create_session, command_id: command_id}), do: command_id
  defp transaction_tx_id(%{tx_id: tx_id}), do: tx_id

  defp assert_binding_conflicts(context, transaction) do
    changed = [
      %{transaction | expected_owner_epoch: transaction.expected_owner_epoch + 1},
      %{
        transaction
        | expected_owner_incarnation_id: transaction.expected_owner_incarnation_id <> "-changed"
      },
      %{transaction | expected_journal_version: transaction.expected_journal_version + 1},
      %{transaction | canonical_mutation_digest: <<0::256>>},
      %{transaction | canonical_record_bytes: transaction.canonical_record_bytes <> <<0>>}
    ]

    for conflicting <- changed do
      assert {:not_committed, :tx_id_conflict} =
               Store.transact(context.store, conflicting)
    end
  end

  defp rebind_session_transaction(transaction) do
    fields = [
      type: transaction.type,
      session_id: transaction.session_id,
      mutation_domain: transaction.mutation_domain,
      tx_id: transaction.tx_id,
      expected_owner_epoch: transaction.expected_owner_epoch,
      expected_owner_incarnation_id: transaction.expected_owner_incarnation_id,
      expected_journal_version: transaction.expected_journal_version,
      records: transaction.records,
      outbox: transaction.outbox
    ]

    canonical =
      :erlang.term_to_binary(["loopex_store_transaction_v1" | fields], [:deterministic])

    %{
      transaction
      | canonical_record_bytes: canonical,
        canonical_mutation_digest: :crypto.hash(:sha256, canonical)
    }
  end

  defp assert_durable_resolution_replay do
    context = start_store(:local)

    try do
      owned = create_owned(context, unique("durable-resolution"), "durable-resolution-owner")
      committed = commit_tx(owned, "durable-known", 2, "known", "durable-known-event")
      assert {:committed, "durable-known", receipt} = Store.transact(context.store, committed)

      bytes_after_commit = File.read!(context.path)
      assert {:committed, "durable-known", ^receipt} = Store.transact(context.store, committed)
      assert File.read!(context.path) == bytes_after_commit

      refused = commit_tx(owned, "durable-refused", 99, "never", "never-event")

      assert {:not_committed, :stale_journal_version} =
               Store.transact(context.store, refused)

      bytes_after_refusal = File.read!(context.path)

      assert {:not_committed, :stale_journal_version} =
               Store.transact(context.store, refused)

      assert File.read!(context.path) == bytes_after_refusal
      stop(context.pid)

      restarted = restart_local(context)

      assert {:terminal, :committed} =
               Store.transaction_status(
                 restarted.store,
                 owned.session_id,
                 @domain,
                 committed.tx_id
               )

      assert {:terminal, {:not_committed, :stale_journal_version}} =
               Store.transaction_status(restarted.store, owned.session_id, @domain, refused.tx_id)

      assert {:committed, "durable-known", ^receipt} = Store.transact(restarted.store, committed)

      assert {:not_committed, :stale_journal_version} =
               Store.transact(restarted.store, refused)

      assert File.read!(context.path) == bytes_after_refusal
      stop(restarted.pid)

      final = restart_local(restarted)
      assert {:ok, records} = Store.load_records(final.store, owned.session_id, 0, 100)
      assert Enum.map(records, & &1.journal_version) == [1, 2, 3]

      assert {:ok, [%{event_id: "durable-known-event", event_sequence: 1}]} =
               Store.load_events(final.store, owned.session_id, 0, 100)

      stop(final.pid)
    after
      close(context)
    end
  end

  defp assert_terminal_status_recovery do
    each_store(fn context ->
      for observation <- [:committed, :not_committed] do
        owned =
          create_owned(
            context,
            unique("terminal-recovery"),
            unique("terminal-recovery-owner")
          )

        observed =
          case observation do
            :committed ->
              transaction =
                commit_tx(
                  owned,
                  unique("terminal-committed"),
                  2,
                  "committed",
                  unique("terminal-event")
                )

              assert {:committed, _tx_id, _receipt} =
                       Store.transact(context.store, transaction)

              assert {:terminal, :committed} =
                       Store.transaction_status(
                         context.store,
                         owned.session_id,
                         @domain,
                         transaction.tx_id
                       )

              transaction

            :not_committed ->
              transaction =
                commit_tx(
                  owned,
                  unique("terminal-not-committed"),
                  99,
                  "never",
                  unique("terminal-never-event")
                )

              assert {:not_committed, :stale_journal_version} =
                       Store.transact(context.store, transaction)

              assert {:terminal, {:not_committed, :stale_journal_version}} =
                       Store.transaction_status(
                         context.store,
                         owned.session_id,
                         @domain,
                         transaction.tx_id
                       )

              transaction
          end

        assert {:ok, head} =
                 Store.ownership_head(context.store, owned.session_id, @domain)

        {:ok, recovery} =
          Store.advance_owner(
            owned.session_id,
            @domain,
            unique("terminal-recovery-succession"),
            head.owner_epoch,
            head.journal_version,
            unique("terminal-recovery-successor")
          )

        assert {:committed, _tx_id, recovery_receipt} =
                 Store.transact(context.store, recovery)

        assert recovery_receipt.owner_epoch == owned.owner_epoch + 1

        case observation do
          :committed ->
            assert {:committed, _tx_id, _receipt} = Store.transact(context.store, observed)

          :not_committed ->
            assert {:not_committed, :stale_journal_version} =
                     Store.transact(context.store, observed)
        end

        old_owner =
          commit_tx(
            %{owned | journal_version: recovery_receipt.journal_version},
            unique("status-grants-no-authority"),
            recovery_receipt.journal_version,
            "never",
            unique("status-never-event")
          )

        assert {:not_committed, :stale_owner_epoch} =
                 Store.transact(context.store, old_owner)
      end
    end)
  end

  defp assert_status_unavailable do
    for kind <- [:memory, :local] do
      pair = {:session_journal_advance_owner, :after_linearization_before_result}
      probe = FaultProbe.start(%{pair => [:continue, :return_unknown]})
      context = start_store(kind, probe)

      try do
        owned = create_owned(context, unique("unavailable"), "unavailable-owner")

        {:ok, ambiguous} =
          Store.advance_owner(
            owned.session_id,
            @domain,
            "unavailable-unknown-succession",
            owned.owner_epoch,
            owned.journal_version,
            "unavailable-successor"
          )

        owner = OwnerLane.new(context.store)

        assert {{:commit_unknown, "unavailable-unknown-succession"}, fenced} =
                 OwnerLane.transact(owner, ambiguous)

        kill(context.pid)

        assert :unavailable =
                 Store.transaction_status(
                   context.store,
                   owned.session_id,
                   @domain,
                   ambiguous.tx_id
                 )

        assert :unavailable = Store.ownership_head(context.store, owned.session_id, @domain)

        {:ok, bypass} =
          Store.advance_owner(
            owned.session_id,
            @domain,
            "unavailable-bypass",
            owned.owner_epoch,
            owned.journal_version,
            "unavailable-bypass-owner"
          )

        assert {{:fenced, :commit_unknown}, ^fenced} = OwnerLane.transact(fenced, bypass)

        assert {{:commit_unknown, "unavailable-unknown-succession"}, still_fenced} =
                 OwnerLane.transact(fenced, ambiguous)

        assert OwnerLane.fenced?(still_fenced, ambiguous)
      after
        close(context)
        FaultProbe.stop(probe)
      end
    end
  end

  defp assert_cold_vm_replay(path) do
    executable = System.find_executable("elixir") || raise "elixir executable unavailable"
    core_ebin = Loopex.Store |> :code.which() |> List.to_string() |> Path.dirname()
    local_ebin = Log |> :code.which() |> List.to_string() |> Path.dirname()

    script = """
    state_module = Loopex.Store.Local.State

    if Code.loaded?(state_module) do
      System.halt(20)
    end

    with {:ok, frames, :complete} <- Loopex.Store.Local.Log.read(#{inspect(path)}),
         true <- frames != [],
         true <- Code.loaded?(state_module),
         {:ok, _state} <- state_module.replay(frames) do
      IO.write("cold-replay-ok")
    else
      _other -> System.halt(21)
    end
    """

    assert {"cold-replay-ok", 0} =
             System.cmd(
               executable,
               ["--erl", "+S 1:1", "-pa", core_ebin, "-pa", local_ebin, "-e", script],
               stderr_to_stdout: true
             )
  end

  defp append_fencing_bypass(
         path,
         transaction,
         current_owner_epoch,
         current_owner_incarnation_id,
         current_event_sequence
       ) do
    first_version = transaction.expected_journal_version + 1

    records =
      transaction.records
      |> Enum.with_index(first_version)
      |> Enum.map(fn {payload, journal_version} ->
        %{
          journal_version: journal_version,
          owner_epoch: current_owner_epoch,
          owner_incarnation_id: current_owner_incarnation_id,
          payload: payload
        }
      end)

    first_sequence = current_event_sequence + 1

    events =
      transaction.outbox
      |> Enum.with_index(first_sequence)
      |> Enum.map(fn {event, event_sequence} ->
        Map.put(event, :event_sequence, event_sequence)
      end)

    last_version = first_version + length(records) - 1

    event_sequences =
      case events do
        [] -> nil
        _events -> %{first: first_sequence, last: first_sequence + length(events) - 1}
      end

    frame = %{
      schema_version: 1,
      transition_id: :session_journal_commit,
      transaction: transaction,
      resolution: %{
        status: :committed,
        receipt: %{
          type: :session_commit,
          journal_versions: %{first: first_version, last: last_version},
          event_sequences: event_sequences
        }
      },
      records: records,
      events: events
    }

    {:ok, bytes} = Log.encode(frame)
    File.write!(path, bytes, [:append, :binary])
  end

  defp assert_replay_mutation_corpus do
    mutations = [
      :version_gap,
      :version_reset,
      :version_duplicate,
      :version_out_of_order,
      :decreasing_epoch,
      :incarnation_without_succession,
      :missing_succession,
      :duplicate_transaction,
      :out_of_order_frame
    ]

    for mutation <- mutations do
      context = start_store(:local)

      try do
        owned = create_owned(context, unique("mutation"), "mutation-owner")

        {:ok, multi} =
          Store.session_commit(
            owned.session_id,
            @domain,
            unique("multi"),
            1,
            "mutation-owner",
            2,
            [%{kind: :fact, value: "one"}, %{kind: :fact, value: "two"}],
            []
          )

        assert {:committed, _tx_id, _receipt} = Store.transact(context.store, multi)

        {:ok, successor} =
          Store.advance_owner(
            owned.session_id,
            @domain,
            unique("successor"),
            1,
            4,
            "mutation-successor"
          )

        assert {:committed, _tx_id, _receipt} = Store.transact(context.store, successor)

        current = %{
          session_id: owned.session_id,
          owner_epoch: 2,
          owner_id: "mutation-successor",
          journal_version: 5
        }

        final = commit_tx(current, unique("final"), 5, "final", unique("final-event"))
        assert {:committed, _tx_id, _receipt} = Store.transact(context.store, final)
        stop(context.pid)

        assert {:ok, frames, :complete} = Log.read(context.path)
        broken = mutate_frames(frames, mutation)
        write_frames(context.path, broken)

        assert {:error, {:invalid_history, _index, _reason}} =
                 Local.start_link(path: context.path, recover_stale_writer: true)
      after
        close(context)
      end
    end
  end

  defp mutate_frames(frames, :version_gap) do
    update_record_frame(frames, 2, fn [first, second] ->
      [first, %{second | journal_version: second.journal_version + 1}]
    end)
  end

  defp mutate_frames(frames, :version_reset) do
    update_record_frame(frames, 2, fn [first, second] ->
      [%{first | journal_version: 1}, second]
    end)
  end

  defp mutate_frames(frames, :version_duplicate) do
    update_record_frame(frames, 2, fn [first, second] ->
      [first, %{second | journal_version: first.journal_version}]
    end)
  end

  defp mutate_frames(frames, :version_out_of_order) do
    update_record_frame(frames, 2, &Enum.reverse/1)
  end

  defp mutate_frames(frames, :decreasing_epoch) do
    update_record_frame(frames, 4, fn [record] -> [%{record | owner_epoch: 1}] end)
  end

  defp mutate_frames(frames, :incarnation_without_succession) do
    update_record_frame(frames, 4, fn [record] ->
      [%{record | owner_incarnation_id: "unrecorded-owner"}]
    end)
  end

  defp mutate_frames(frames, :missing_succession), do: List.delete_at(frames, 3)

  defp mutate_frames(frames, :duplicate_transaction),
    do: List.insert_at(frames, 3, Enum.at(frames, 2))

  defp mutate_frames(frames, :out_of_order_frame) do
    frames
    |> List.replace_at(2, Enum.at(frames, 3))
    |> List.replace_at(3, Enum.at(frames, 2))
  end

  defp update_record_frame(frames, index, fun) do
    frame = Enum.at(frames, index)
    List.replace_at(frames, index, %{frame | records: fun.(frame.records)})
  end

  defp write_frames(path, frames) do
    bytes =
      Enum.map_join(frames, fn frame ->
        {:ok, encoded} = Log.encode(frame)
        encoded
      end)

    File.write!(path, bytes, [:binary])
  end

  defp assert_physical_corruption_visible do
    for corruption <- [:payload_digest, :header_size, :header_digest, :short_garbage] do
      context = start_store(:local)

      try do
        _owned = create_owned(context, unique("corrupt"), "owner-corrupt")
        stop(context.pid)
        bytes = File.read!(context.path)

        corrupted =
          case corruption do
            :payload_digest -> flip_byte(bytes, byte_size(bytes) - 1)
            :header_size -> flip_byte(bytes, 5)
            :header_digest -> flip_byte(bytes, 9)
            :short_garbage -> bytes <> "NO"
          end

        File.write!(context.path, corrupted, [:binary])

        assert {:error, {:store_corrupt, _offset}} =
                 Local.start_link(path: context.path, recover_stale_writer: true)

        assert File.read!(context.path) == corrupted
      after
        close(context)
      end
    end
  end

  defp flip_byte(bytes, offset) do
    <<prefix::binary-size(^offset), byte, suffix::binary>> = bytes
    prefix <> <<Bitwise.bxor(byte, 1)>> <> suffix
  end

  defp restart_local(context) do
    {:ok, pid} = Local.start_link(path: context.path, recover_stale_writer: true)
    {:ok, store} = Store.new(Local, pid)
    %{context | pid: pid, store: store}
  end

  defp genesis(label), do: %{kind: :session_genesis, label: label}

  defp store_path do
    root = System.fetch_env!("LOOPEX_HOME")
    Path.join([root, "store-conformance", "#{unique("store")}.log"])
  end

  defp unique(prefix),
    do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"

  defp kill(pid) do
    reference = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^reference, :process, ^pid, _reason} -> :ok
    after
      2_000 -> raise "Store process survived an untrappable kill"
    end
  end

  defp stop(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  end

  defp close(%{pid: pid, path: path}) do
    stop(pid)
    if is_binary(path), do: File.rm(path)
  end
end
