Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)

defmodule Loopex.PolicyAnswerAdmissionTest do
  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.Runtime.{SessionConfiguration, SessionState}
  alias Loopex.M1RuntimeTestStore, as: TestStore

  defmodule HeldPolicy do
    @moduledoc false
    @behaviour Loopex.Policy

    @impl Loopex.Policy
    def decide(request) do
      case Map.get(request, :interaction_response) do
        nil ->
          {:defer,
           %{
             kind: :choice,
             prompt: "Allow this write?",
             choices: [%{id: "allow", label: "Allow"}, %{id: "deny", label: "Deny"}],
             decision_ref: "PRIVATE_POLICY_REFERENCE_CANARY",
             expires_in_ms: 60_000
           }}

        %{answer: %{choice_id: choice}} ->
          send(Process.whereis(__MODULE__), {:policy_answer_callback, self(), choice})

          receive do
            :release -> if choice == "allow", do: {:allow, nil}, else: {:deny, :policy_denied}
          after
            5_000 -> {:deny, :policy_unavailable}
          end
      end
    end
  end

  defmodule MinimalPolicy do
    @moduledoc false
    @behaviour Loopex.Policy
    @impl Loopex.Policy
    def decide(request) do
      case Map.get(request, :interaction_response) do
        nil ->
          {:defer,
           %{
             kind: :choice,
             prompt: "?",
             choices: [%{id: "allow", label: "A"}],
             expires_in_ms: 600_000
           }}

        _answer ->
          HeldPolicy.decide(request)
      end
    end
  end

  setup do
    Process.register(self(), HeldPolicy)
    :ok
  end

  test "answer admission advances the public cursor before policy resolution and historical attachments retain all three states" do
    {fixture, session, attachment, requested} = pending()

    {:ok, pending_attachment} =
      Loopex.attach(fixture.runtime, session,
        after_event_sequence: requested.event_sequence,
        replace_attachment_id: attachment.attachment_id
      )

    pending = Loopex.snapshot(pending_attachment)
    assert map_size(pending.open_interaction) == 10
    assert pending.open_interaction["producer"] == "policy_defer"
    assert pending.open_interaction["kind"] == "choice"
    assert pending.open_interaction["status"] == "pending"
    assert pending.open_interaction["interaction_id"] == requested["interaction_id"]
    assert {:ok, before} = Loopex.session_status(fixture.runtime, session)
    assert before.event_sequence == requested.event_sequence
    assert before.open_interaction == pending.open_interaction
    assert {:error, :stale_attachment} = Loopex.next_event(attachment)
    assert {:error, :session_unavailable} = Loopex.command(attachment, answer(requested))

    assert {:accepted, "answer"} = Loopex.command(pending_attachment, answer(requested))
    assert_receive {:policy_answer_callback, callback, "allow"}, 4_000
    monitor = Process.monitor(callback)
    admitted = await_event(fixture, session, "interaction.answer_admitted")

    assert answer_data(admitted) == %{
             "interaction_id" => requested["interaction_id"],
             "run_id" => requested["run_id"],
             "turn" => requested["turn"],
             "tool_call_id" => requested["tool_call_id"],
             "producer" => "policy_defer",
             "interaction_kind" => "choice",
             "status" => "answered",
             "answer_choice_id" => "allow",
             "answer_command_id" => "answer"
           }

    assert admitted.event_sequence == requested.event_sequence + 1
    assert {:ok, status} = Loopex.session_status(fixture.runtime, session)
    assert status.event_sequence == admitted.event_sequence
    assert status.open_interaction["status"] == "answered"
    assert status.open_interaction["answer_choice_id"] == "allow"
    assert status.open_interaction["answer_command_id"] == "answer"
    assert map_size(status.open_interaction) == 12
    assert Loopex.AgentLoopTestExecutor.jobs(fixture.executor) == []
    refute Enum.any?(Fixture.events(fixture, session), &(&1.kind == "tool.started"))

    {:ok, answered_attachment} =
      Loopex.attach(fixture.runtime, session, after_event_sequence: admitted.event_sequence)

    assert Loopex.snapshot(answered_attachment).open_interaction == status.open_interaction
    assert {:accepted, "answer"} = Loopex.command(answered_attachment, answer(requested))

    assert {:error, :idempotency_conflict} =
             Loopex.command(
               answered_attachment,
               %{answer(requested) | choice_id: "deny"}
             )

    refute_receive {:policy_answer_callback, _, _}, 0
    assert Fixture.events(fixture, session) |> Enum.count(&(&1.kind == admitted.kind)) == 1
    records = Fixture.records(fixture, session)
    [record] = Enum.filter(records, &(&1.payload.kind == "policy_interaction_answer_admitted_v1"))

    assert Map.keys(record.payload) |> Enum.sort() ==
             Enum.sort([
               :kind
               | ~w(command_id command_digest command_type admission interaction_id choice_id answer_digest)
             ])

    assert record.payload["answer_digest"] == Loopex.Interaction.digest(%{choice_id: "allow"})

    assert {:ok, recovered} =
             SessionState.recover(session, records, Fixture.events(fixture, session))

    assert SessionState.open_interaction(recovered) == status.open_interaction

    refute inspect({status, pending, Loopex.snapshot(answered_attachment), admitted}) =~
             "PRIVATE_POLICY_REFERENCE_CANARY"

    send(callback, :release)
    assert_receive {:DOWN, ^monitor, :process, ^callback, _}, 4_000
    resolved = await_event(fixture, session, "interaction.resolved", 8_000)
    _finished = await_event(fixture, session, "run.finished", 8_000)
    assert resolved.event_sequence > admitted.event_sequence
    assert {:ok, final} = Loopex.session_status(fixture.runtime, session)
    assert final.open_interaction == nil

    for {anchor, expected} <- [
          {requested.event_sequence, pending.open_interaction},
          {admitted.event_sequence, status.open_interaction},
          {resolved.event_sequence, nil}
        ] do
      assert {:ok, historical} =
               Loopex.attach(fixture.runtime, session, after_event_sequence: anchor)

      snapshot = Loopex.snapshot(historical)
      assert snapshot.event_sequence == anchor
      assert snapshot.open_interaction == expected
    end
  end

  test "the largest actual transaction identity and a long admitted call retain a bounded answer event dominated by its question" do
    {fixture, session, attachment, requested} =
      pending(
        call_id: String.duplicate("c", 8_192),
        policy: MinimalPolicy,
        policy_identity: %{"id" => "p", "revision" => "1"}
      )

    records = Fixture.records(fixture, session)
    assert {:ok, state} = SessionState.recover(session, records, Fixture.events(fixture, session))
    command = %{answer(requested) | command_id: String.duplicate("a", 256)}
    assert {:ok, proposal} = SessionState.propose(state, command)
    [event] = proposal.events
    question = Enum.find(records, &(&1.payload.kind == "interaction_requested_v1"))
    assert {:ok, _, event_bytes} = Loopex.Store.normalize_and_measure_item(:event, event)

    assert {:ok, _, question_bytes} =
             Loopex.Store.normalize_and_measure_item(:record, question.payload)

    assert event_bytes <= question_bytes
    assert event_bytes <= 65_536

    assert {:ok, transaction} =
             Loopex.Store.session_commit(
               session,
               "session",
               proposal.tx_id,
               state.owner_epoch,
               state.owner_incarnation_id,
               state.journal_version,
               proposal.records,
               proposal.events
             )

    assert :ok = Loopex.Store.validate_transaction(transaction)
    assert {:accepted, id} = Loopex.command(attachment, command)
    assert id == command.command_id
    assert_receive {:policy_answer_callback, callback, "allow"}, 4_000
    monitor = Process.monitor(callback)
    assert Map.delete(await_event(fixture, session, event.kind), :event_sequence) == event
    assert Loopex.AgentLoopTestExecutor.jobs(fixture.executor) == []
    send(callback, :release)
    assert_receive {:DOWN, ^monitor, :process, ^callback, _}, 4_000
  end

  test "unknown answer transactions preserve one exact proposal and publish neither an answer nor a callback before resolution" do
    for phase <- [
          :before_linearization,
          :after_linearization_before_result,
          :recovery_representation
        ] do
      {fixture, session, attachment, requested} = pending()

      :ok =
        TestStore.hold_next_record_before_linearization(
          fixture.store,
          "policy_interaction_answer_admitted_v1",
          self()
        )

      parent = self()

      caller =
        spawn(fn ->
          send(parent, {:answer_result, self(), Loopex.command(attachment, answer(requested))})
        end)

      caller_monitor = Process.monitor(caller)
      assert_receive {:record_held_before_linearization, waiter, _, _, transaction}, 5_000
      assert [proposed] = transaction.records
      assert proposed.kind == "policy_interaction_answer_admitted_v1"
      assert [proposed_event] = transaction.outbox
      assert proposed_event.kind == "interaction.answer_admitted"
      refute_receive {:answer_result, ^caller, _}, 0
      refute_receive {:policy_answer_callback, _, _}, 0
      refute Enum.any?(Fixture.events(fixture, session), &(&1.kind == proposed_event.kind))
      assert Loopex.AgentLoopTestExecutor.jobs(fixture.executor) == []
      :ok = TestStore.inject(fixture.store, {:session_journal_commit, phase})
      TestStore.release(waiter)
      assert_receive {:answer_result, ^caller, {:error, :commit_unknown}}, 5_000
      assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 5_000
      assert_receive {:policy_answer_callback, callback, "allow"}, 4_000
      callback_monitor = Process.monitor(callback)
      admitted = await_event(fixture, session, "interaction.answer_admitted")
      assert Map.delete(admitted, :event_sequence) == proposed_event

      [retained] =
        Enum.filter(
          Fixture.records(fixture, session),
          &(&1.payload.kind == "policy_interaction_answer_admitted_v1")
        )

      assert retained.payload == proposed

      assert {:ok, binding} = Loopex.Store.immutable_binding(transaction)

      resolution =
        TestStore.inspect_state(fixture.store).resolutions[
          {session, "session", transaction.tx_id}
        ]

      assert resolution.binding == binding
      assert {:committed, tx_id, _receipt} = resolution.outcome
      assert tx_id == transaction.tx_id

      assert MapSet.member?(TestStore.observed(fixture.store), {:session_journal_commit, phase})
      assert {:accepted, "answer"} = Loopex.command(attachment, answer(requested))
      refute_receive {:policy_answer_callback, _, _}, 0
      send(callback, :release)
      assert_receive {:DOWN, ^callback_monitor, :process, ^callback, _}, 4_000
      _finished = await_event(fixture, session, "run.finished", 8_000)
      assert Enum.count(Fixture.events(fixture, session), &(&1.kind == admitted.kind)) == 1
      Fixture.stop(fixture)
    end
  end

  test "replay and snapshot reduction refuse retired answer rows, altered preimages and impossible public answer transitions" do
    {fixture, session, attachment, requested} = pending()
    assert {:accepted, "answer"} = Loopex.command(attachment, answer(requested))
    assert_receive {:policy_answer_callback, callback, "allow"}, 4_000
    monitor = Process.monitor(callback)
    admitted = await_event(fixture, session, "interaction.answer_admitted")
    records = Fixture.records(fixture, session)
    events = Fixture.events(fixture, session)
    configuration = SessionConfiguration.public_view(hd(records).payload["initial_configuration"])

    for transform <- [
          &Map.put(&1, :kind, "command_admitted"),
          &Map.put(&1, :kind, "interaction_answer_admitted_v1"),
          &Map.delete(&1, "answer_digest"),
          &Map.put(&1, "answer_digest", String.duplicate("0", 64)),
          &Map.put(&1, "command_digest", String.duplicate("0", 64)),
          &Map.put(&1, "choice_id", "invented"),
          &Map.put(&1, "command_id", "different"),
          &Map.put(&1, "private", "canary")
        ] do
      altered =
        Enum.map(records, fn row ->
          if row.payload.kind == "policy_interaction_answer_admitted_v1",
            do: %{row | payload: transform.(row.payload)},
            else: row
        end)

      assert {:error, _} = SessionState.recover(session, altered, events)
    end

    for altered <- [
          Enum.reject(events, &(&1.kind == admitted.kind)),
          events ++ [admitted],
          Enum.map(events, fn event ->
            if event.kind == admitted.kind,
              do: Map.put(event, "producer", "model_tool"),
              else: event
          end),
          Enum.map(events, fn event ->
            if event.kind == admitted.kind,
              do: Map.put(event, "answer_choice_id", "invented"),
              else: event
          end),
          Enum.map(events, fn event ->
            if event.kind == admitted.kind, do: Map.put(event, "run_id", "other-run"), else: event
          end),
          Enum.map(events, fn event ->
            if event.kind == admitted.kind, do: Map.put(event, "unexpected", true), else: event
          end),
          [admitted]
        ] do
      stamped =
        Enum.with_index(altered, 1)
        |> Enum.map(fn {event, sequence} -> Map.put(event, :event_sequence, sequence) end)

      assert {:error, _} = SessionState.recover(session, records, stamped)
      {:ok, scan} = SessionState.start_snapshot_scan(session, nil, configuration)

      case SessionState.scan_snapshot_page(scan, stamped) do
        {:error, _} ->
          :ok

        {:ok, scan} ->
          assert {:ok, result} = SessionState.finish_snapshot_scan(scan)
          # Removing the answer is a valid earlier public view, but cannot be
          # admitted beside private history that has already retained it.
          assert result.open_interaction["status"] == "pending"
      end
    end

    send(callback, :release)
    assert_receive {:DOWN, ^monitor, :process, ^callback, _}, 4_000
  end

  defp pending(options \\ []) do
    call_id = Keyword.get(options, :call_id, "c1")

    fixture =
      Fixture.start(
        Keyword.merge(
          [
            script: [
              %{
                text: "write",
                calls: [%{id: call_id, name: "write", arguments: %{"path" => "a"}}]
              },
              %{text: "done", calls: []}
            ],
            policy: HeldPolicy
          ],
          Keyword.drop(options, [:call_id])
        )
      )

    on_exit(fn -> Fixture.stop(fixture) end)
    assert {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
    assert {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)

    assert {:accepted, "prompt"} =
             Loopex.command(
               attachment,
               %{type: :prompt, command_id: "prompt", content: "write"}
             )

    {fixture, session, attachment, await_event(fixture, session, "interaction.requested")}
  end

  defp answer(requested),
    do: %{
      type: :interaction_answer,
      command_id: "answer",
      interaction_id: requested["interaction_id"],
      choice_id: "allow"
    }

  defp answer_data(event), do: Map.drop(event, [:kind, :event_id, :event_sequence])

  defp await_event(fixture, session, kind, remaining \\ 2_000) do
    case Enum.find(Fixture.events(fixture, session), &(&1.kind == kind)) do
      nil when remaining > 0 ->
        Process.sleep(20)
        await_event(fixture, session, kind, remaining - 20)

      nil ->
        flunk("no #{kind} event arrived")

      event ->
        event
    end
  end
end
