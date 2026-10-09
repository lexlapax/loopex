Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)

defmodule Loopex.AdmissionObservationStore do
  @moduledoc false
  @behaviour Loopex.Store
  alias Loopex.M1RuntimeTestStore, as: Store

  @impl true
  def transact(%{store: store, gate: gate} = ref, transaction) do
    observe_call(ref, :transact)
    caller = self()

    action =
      Agent.get_and_update(gate, fn state ->
        matches =
          if state.transaction_id do
            transaction.tx_id == state.transaction_id
          else
            Enum.any?(Map.get(transaction, :records, []), fn record ->
              (record["command_id"] || get_in(record, ["command", "command_id"])) == state.target
            end)
          end

        if state.target && matches do
          index = length(state.calls) + 1

          call = %{
            transaction: transaction,
            caller: caller,
            at: System.monotonic_time(:millisecond)
          }

          {{state.mode, index, state.observer},
           %{state | calls: state.calls ++ [call], transaction_id: transaction.tx_id}}
        else
          {:pass, state}
        end
      end)

    case action do
      :pass ->
        Store.transact(store, transaction)

      {:after_commit, index, _observer} when index <= 2 ->
        Store.transact(store, transaction)
        {:commit_unknown, transaction.tx_id}

      {:hold_second, 1, _observer} ->
        {:commit_unknown, transaction.tx_id}

      {mode, index, _observer} when index <= 2 and mode != :hold_second ->
        {:commit_unknown, transaction.tx_id}

      {:unknown, _index, _observer} ->
        {:commit_unknown, transaction.tx_id}

      {:refuse, _index, _observer} ->
        {:not_committed, :refused_by_test_store}

      {mode, _index, observer} when mode in [:hold, :hold_second, :hold_refuse, :after_commit] ->
        send(observer, {:resolution_held, self(), transaction})

        receive do
          :release ->
            if mode == :hold_refuse,
              do: {:not_committed, :refused_by_test_store},
              else: Store.transact(store, transaction)
        end

      {_mode, _index, _observer} ->
        Store.transact(store, transaction)
    end
  end

  @impl true
  def creation_recovery(ref, request) do
    observe_call(ref, :creation_recovery)
    Store.creation_recovery(ref.store, request)
  end

  @impl true
  def transaction_status(ref, session, domain, id) do
    observe_call(ref, :transaction_status)
    Store.transaction_status(ref.store, session, domain, id)
  end

  @impl true
  def runtime_command(ref, command) do
    observe_call(ref, :runtime_command)
    Store.runtime_command(ref.store, command)
  end

  @impl true
  def ownership_head(ref, session, domain) do
    observe_call(ref, :ownership_head)
    Store.ownership_head(ref.store, session, domain)
  end

  @impl true
  def load_records(ref, session, version, limit) do
    observe_call(ref, :load_records)
    Store.load_records(ref.store, session, version, limit)
  end

  @impl true
  def load_events(ref, session, sequence, limit) do
    observe_call(ref, :load_events)
    Store.load_events(ref.store, session, sequence, limit)
  end

  defp observe_call(ref, kind) do
    caller = self()

    Agent.update(
      ref.gate,
      &%{
        &1
        | callback_counts:
            Map.update(&1.callback_counts, {caller, kind}, 1, fn count -> count + 1 end)
      }
    )
  end
end

defmodule Loopex.CommandDispositionTest do
  @moduledoc false
  use ExUnit.Case, async: false
  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.AgentLoopTestModel
  alias Loopex.M1RuntimeTestStore
  alias Loopex.Runtime.SessionState

  defp fixture(options) do
    {store, _} = M1RuntimeTestStore.start_store(label: "admission-observation")
    observer = self()

    {:ok, gate} =
      Agent.start(fn ->
        %{
          target: nil,
          transaction_id: nil,
          mode: :pass,
          calls: [],
          observer: observer,
          callback_counts: %{}
        }
      end)

    reference = %{store: store, gate: gate}

    fixture =
      Fixture.start(
        Keyword.merge(options, store: reference, store_module: Loopex.AdmissionObservationStore)
      )

    fixture = Map.merge(fixture, %{store: store, gate: gate})

    on_exit(fn ->
      Fixture.stop(fixture)
      Agent.stop(gate)
    end)

    {:ok, session} = Loopex.create_session(fixture.runtime, %{}, command_id: "create")
    {:ok, attachment} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)
    {fixture, session, attachment}
  end

  defp arm(fixture, id, mode),
    do:
      Agent.update(fixture.gate, &%{&1 | target: id, transaction_id: nil, mode: mode, calls: []})

  defp calls(fixture), do: Agent.get(fixture.gate, & &1.calls)

  defp owner_callbacks(fixture, owner),
    do:
      Agent.get(fixture.gate, fn state ->
        Map.filter(state.callback_counts, fn {{caller, _kind}, _count} -> caller == owner end)
      end)

  defp pass(fixture), do: Agent.update(fixture.gate, &%{&1 | target: nil, mode: :pass})
  defp prompt(id), do: %{type: :prompt, command_id: id, content: "implement"}

  defp coordinator(fixture) do
    {:ok, %{sessions: sessions}} = Loopex.Runtime.children(fixture.runtime)
    [{_, coordinator, _, _}] = DynamicSupervisor.which_children(sessions)
    coordinator
  end

  defp await(fun, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 5_000

    case fun.() do
      false ->
        assert System.monotonic_time(:millisecond) < deadline
        Process.sleep(5)
        await(fun, deadline)

      value ->
        value
    end
  end

  defp finish(attachment) do
    await(fn ->
      case Loopex.next_event(attachment) do
        {:ok, %{kind: "run.finished"} = event} -> event
        _ -> false
      end
    end)
  end

  defp await_worker_result(owner, kind) do
    reference =
      Enum.find_value(:sys.get_state(owner).in_flight, fn
        {reference, {^kind, _, _, _}} -> reference
        {reference, {^kind, _, _}} -> reference
        _other -> nil
      end)

    assert is_reference(reference)

    await(fn ->
      Enum.any?(:queue.to_list(:sys.get_state(owner).unknown_admission.deferred), fn
        {^reference, _result} -> true
        _other -> false
      end)
    end)
  end

  # Concept: uncertain commitment never resamples an authored admission clock.
  # Technical depth: the real Store resolution holds the exact original bytes
  # across the authored cutoff. Adoption retains accepted disposition and ends
  # the unstaged run through ordinary cleanup without opening a provider attempt.
  test "an uncertain admitted ceiling expires before staging without changing its disposition" do
    {fixture, session, attachment} = fixture(script: [%{text: "must not dispatch"}])

    command =
      Map.put(prompt("ceiling-unknown"), :bounds, %{
        deadline_at_ms: System.system_time(:millisecond) + 1_000
      })

    arm(fixture, "ceiling-unknown", :after_commit)
    assert {:error, :commit_unknown} = Loopex.command(attachment, command)
    assert_receive {:resolution_held, resolver, original}, 5_000
    monitor = Process.monitor(resolver)
    [admission] = Enum.filter(original.records, &(&1["command_id"] == "ceiling-unknown"))
    assert admission["admission"] == "accepted"
    assert admission["authored_bounds"] == %{"deadline_at_ms" => command.bounds.deadline_at_ms}
    remaining = max(command.bounds.deadline_at_ms - System.system_time(:millisecond), 0)
    Process.sleep(remaining)
    send(resolver, :release)
    terminal = finish(attachment)
    assert_receive {:DOWN, ^monitor, :process, ^resolver, _}, 5_000
    assert terminal["outcome"] == "bound_reached"
    assert terminal["bound"] == "deadline"
    assert terminal["declared_limit"] == command.bounds.deadline_at_ms
    assert AgentLoopTestModel.dispatched(fixture.model) == []
    assert Enum.all?(calls(fixture), &(&1.transaction == original))
    assert {:accepted, "ceiling-unknown"} = Loopex.command(attachment, command)

    assert {:ok, recovered} =
             SessionState.recover(
               session,
               Fixture.records(fixture, session),
               Fixture.events(fixture, session)
             )

    assert {:replayed, {:accepted, "ceiling-unknown"}} =
             SessionState.propose(recovered, command, %{})
  end

  test "observations retain committed admission and refusal through replay without Store calls" do
    {fixture, session, attachment} = fixture(script: [%{text: "done"}])

    assert {:ok, {:pending, nil, :commit_unknown, nil}} =
             Loopex.command_disposition(attachment, "missing")

    assert {:error, :owner_unavailable} = Loopex.command_disposition(nil, "missing")
    assert {:error, :owner_unavailable} = Loopex.command_disposition(attachment, "")

    assert {:error, :owner_unavailable} =
             Loopex.command_disposition(attachment, String.duplicate("x", 65_537))

    assert {:accepted, "prompt"} = Loopex.command(attachment, prompt("prompt"))
    terminal = finish(attachment)
    run = terminal["run_id"]

    assert {:ok, {:committed, :admitted, :accepted, ^run}} =
             Loopex.command_disposition(attachment, "prompt")

    assert {:error, :no_active_run} =
             Loopex.command(attachment, %{type: :abort, command_id: "refusal"})

    owner = coordinator(fixture)
    before = owner_callbacks(fixture, owner)

    assert {:ok, {:committed, :refused, :no_active_run, nil}} =
             Loopex.command_disposition(attachment, "refusal")

    records = Fixture.records(fixture, session)

    assert {:ok, recovered} =
             SessionState.recover(session, records, Fixture.events(fixture, session))

    assert SessionState.command_disposition(recovered, "prompt") ==
             {:committed, :admitted, :accepted, run}

    assert SessionState.command_disposition(recovered, "missing") ==
             {:pending, nil, :commit_unknown, nil}

    assert calls(fixture) == []
    assert owner_callbacks(fixture, owner) == before

    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, _}, 5_000
    assert {:ok, ^session} = Loopex.resume_session(fixture.runtime, session, command_id: "resume")
    assert {:ok, resumed} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)

    assert {:ok, {:committed, :admitted, :accepted, ^run}} =
             Loopex.command_disposition(resumed, "prompt")

    assert {:ok, {:committed, :refused, :no_active_run, nil}} =
             Loopex.command_disposition(resumed, "refusal")

    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1
  end

  test "the timer resolves one exact original transaction without a second authored command" do
    {fixture, session, attachment} = fixture(script: [%{text: "done"}])
    arm(fixture, "unknown", :hold)
    assert {:error, :commit_unknown} = Loopex.command(attachment, prompt("unknown"))
    assert_receive {:resolution_held, worker, original}, 5_000
    assert Process.alive?(worker)

    assert {:ok, {:pending, nil, :commit_unknown, nil}} =
             Loopex.command_disposition(attachment, "unknown")

    assert {:error, :commit_unknown} = Loopex.command(attachment, prompt("another"))
    assert AgentLoopTestModel.dispatched(fixture.model) == []
    assert Agent.get(fixture.executor, & &1.jobs) == []
    count = length(calls(fixture))
    before = owner_callbacks(fixture, coordinator(fixture))

    for _ <- 1..10,
        do:
          assert(
            {:ok, {:pending, nil, :commit_unknown, nil}} ==
              Loopex.command_disposition(attachment, "unknown")
          )

    assert length(calls(fixture)) == count
    assert owner_callbacks(fixture, coordinator(fixture)) == before
    monitor = Process.monitor(worker)
    send(worker, :release)
    terminal = finish(attachment)
    assert terminal["outcome"] == "completed"
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 5_000
    run = terminal["run_id"]

    assert {:ok, {:committed, :admitted, :accepted, ^run}} =
             Loopex.command_disposition(attachment, "unknown")

    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1
    recorded = calls(fixture)
    assert length(recorded) == 3
    assert Enum.all?(recorded, &(&1.transaction == original))
    assert Enum.at(recorded, 1).at - hd(recorded).at >= 100
    assert Enum.at(recorded, 2).at - Enum.at(recorded, 1).at >= 100
    assert hd(recorded).caller == coordinator(fixture)
    refute Enum.at(recorded, 1).caller == coordinator(fixture)

    assert Enum.count(Fixture.records(fixture, session), &(&1.payload["command_id"] == "unknown")) ==
             1

    assert {:accepted, "unknown"} = Loopex.command(attachment, prompt("unknown"))
    assert length(calls(fixture)) == 3
  end

  test "observation preserves opaque identities and unknown large command IDs" do
    {fixture, _session, attachment} = fixture(script: [%{text: "done"}])
    id = :binary.copy(<<255>>, 256)
    assert {:accepted, ^id} = Loopex.command(attachment, prompt(id))
    terminal = finish(attachment)
    run = terminal["run_id"]

    assert {:ok, {:committed, :admitted, :accepted, ^run}} =
             Loopex.command_disposition(attachment, id)

    assert {:ok, {:pending, nil, :commit_unknown, nil}} =
             Loopex.command_disposition(attachment, :binary.copy(<<0>>, 65_536))

    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1
  end

  test "retained structured admission refusals expose their stable code through replay" do
    {fixture, session, attachment} = fixture(script: [%{text: "must not dispatch"}])
    command = %{type: :prompt, command_id: "oversized", content: String.duplicate("x", 65_536)}

    assert {:error, {:command_admission_too_large, _, _, _, 65_536}} =
             Loopex.command(attachment, command)

    assert {:ok, {:committed, :refused, :command_admission_too_large, nil}} =
             Loopex.command_disposition(attachment, "oversized")

    assert AgentLoopTestModel.dispatched(fixture.model) == []
    assert Agent.get(fixture.executor, & &1.jobs) == []

    assert {:ok, recovered} =
             SessionState.recover(
               session,
               Fixture.records(fixture, session),
               Fixture.events(fixture, session)
             )

    assert {:committed, :refused, :command_admission_too_large, nil} =
             SessionState.command_disposition(recovered, "oversized")
  end

  test "a conclusive refusal clears the fence but missing identities remain pending" do
    {fixture, _session, attachment} = fixture(script: [%{text: "done"}])
    arm(fixture, "unknown", :refuse)
    assert {:error, :commit_unknown} = Loopex.command(attachment, prompt("unknown"))

    await(fn ->
      Loopex.command_disposition(attachment, "unknown") ==
        {:ok, {:not_committed, nil, :admission_not_committed, nil}}
    end)

    assert {:ok, {:pending, nil, :commit_unknown, nil}} =
             Loopex.command_disposition(attachment, "missing")

    assert AgentLoopTestModel.dispatched(fixture.model) == []
    pass(fixture)
    assert {:accepted, "fresh"} = Loopex.command(attachment, prompt("fresh"))
    assert finish(attachment)["outcome"] == "completed"
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1
  end

  test "worker results wait behind an unknown steer and resume against its committed bytes" do
    {fixture, session, attachment} =
      fixture(
        script: [
          %{
            hold: self(),
            text: "write",
            calls: [%{id: "write-1", name: "write", arguments: %{"path" => "a"}}]
          },
          %{text: "done"}
        ]
      )

    assert {:accepted, "prompt"} = Loopex.command(attachment, prompt("prompt"))
    assert_receive {:holding, model}, 5_000
    arm(fixture, "steer", :hold)

    assert {:error, :commit_unknown} =
             Loopex.command(attachment, %{
               type: :steer,
               command_id: "steer",
               run_id: :sys.get_state(coordinator(fixture)).durable.active_run_id,
               content: "exact retained steer"
             })

    assert_receive {:resolution_held, resolver, _}, 5_000
    send(model, :release)
    owner = coordinator(fixture)
    await_worker_result(owner, :model)

    refute Enum.any?(
             Fixture.records(fixture, session),
             &(String.starts_with?(&1.payload.kind, "model_attempt_settled_") or
                 &1.payload.kind == "effect_intent_committed_v2")
           )

    assert Agent.get(fixture.executor, & &1.jobs) == []
    send(resolver, :release)
    assert finish(attachment)["outcome"] == "completed"
    [_first, second] = AgentLoopTestModel.dispatched(fixture.model)

    assert Enum.any?(
             second.messages,
             &(&1["role"] == "user" and &1["content"] == "exact retained steer")
           )

    assert length(Agent.get(fixture.executor, & &1.jobs)) == 1

    assert {:ok, {:committed, :admitted, :accepted, _}} =
             Loopex.command_disposition(attachment, "steer")
  end

  test "an unknown abort consumes deferred worker signals without losing cleanup evidence" do
    {fixture, _session, attachment} = fixture(script: [%{hold: self(), text: "done"}])
    assert {:accepted, "prompt"} = Loopex.command(attachment, prompt("prompt"))
    assert_receive {:holding, model}, 5_000
    arm(fixture, "abort", :hold)

    assert {:error, :commit_unknown} =
             Loopex.command(attachment, %{type: :abort, command_id: "abort"})

    assert_receive {:resolution_held, resolver, _}, 5_000
    owner = coordinator(fixture)
    send(owner, :advance_work)

    await(fn ->
      :queue.peek(:sys.get_state(owner).unknown_admission.deferred) == {:value, :advance_work}
    end)

    send(model, :release)
    await_worker_result(owner, :model)
    send(resolver, :release)
    assert finish(attachment)["outcome"] == "cancelled"

    assert {:ok, {:committed, :admitted, :accepted, _}} =
             Loopex.command_disposition(attachment, "abort")
  end

  test "the actual fixed backstop joins a blocked resolver and preserves uncertainty" do
    {fixture, session, attachment} = fixture(cleanup_grace_ms: 1, script: [%{text: "done"}])
    arm(fixture, "unknown", :hold_second)
    assert {:error, :commit_unknown} = Loopex.command(attachment, prompt("unknown"))
    assert_receive {:resolution_held, resolver, _}, 5_000
    monitor = Process.monitor(resolver)
    owner = coordinator(fixture)
    cutoff = :sys.get_state(owner).unknown_admission.deadline
    assert_receive {:DOWN, ^monitor, :process, ^resolver, _}, 25_000
    assert System.monotonic_time(:millisecond) >= cutoff
    assert :sys.get_state(owner).unknown_admission.expired

    assert {:ok, {:pending, nil, :commit_unknown, nil}} =
             Loopex.command_disposition(attachment, "unknown")

    assert {:error, :commit_unknown} = Loopex.command(attachment, prompt("unknown"))
    assert length(calls(fixture)) == 2
    refute Enum.any?(Fixture.records(fixture, session), &(&1.payload["command_id"] == "unknown"))
    assert AgentLoopTestModel.dispatched(fixture.model) == []
  end

  test "uncertainty after persistence adopts the original admission exactly once" do
    {fixture, session, attachment} = fixture(script: [%{text: "done"}])
    arm(fixture, "unknown", :after_commit)
    assert {:error, :commit_unknown} = Loopex.command(attachment, prompt("unknown"))
    assert_receive {:resolution_held, resolver, original}, 5_000
    assert AgentLoopTestModel.dispatched(fixture.model) == []

    assert {:ok, {:pending, nil, :commit_unknown, nil}} =
             Loopex.command_disposition(attachment, "unknown")

    assert Enum.count(Fixture.records(fixture, session), &(&1.payload["command_id"] == "unknown")) ==
             1

    send(resolver, :release)
    terminal = finish(attachment)
    assert terminal["outcome"] == "completed"
    assert Enum.all?(calls(fixture), &(&1.transaction == original))
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1

    assert Enum.count(Fixture.events(fixture, session), &(&1.kind == "user.message_appended")) ==
             1

    assert Enum.count(Fixture.events(fixture, session), &(&1.kind == "run.started")) == 1
    assert Enum.count(Fixture.events(fixture, session), &(&1.kind == "run.finished")) == 1
  end

  test "conclusive non-commit releases deferred results without inventing a steer" do
    {fixture, _session, attachment} = fixture(script: [%{hold: self(), text: "done"}])
    assert {:accepted, "prompt"} = Loopex.command(attachment, prompt("prompt"))
    assert_receive {:holding, model}, 5_000
    owner = coordinator(fixture)
    run = :sys.get_state(owner).durable.active_run_id
    arm(fixture, "steer", :hold_refuse)

    assert {:error, :commit_unknown} =
             Loopex.command(attachment, %{
               type: :steer,
               command_id: "steer",
               run_id: run,
               content: "must not appear"
             })

    assert_receive {:resolution_held, resolver, _}, 5_000
    send(model, :release)
    await_worker_result(owner, :model)
    send(resolver, :release)
    assert finish(attachment)["outcome"] == "completed"

    assert {:ok, {:not_committed, nil, :admission_not_committed, nil}} =
             Loopex.command_disposition(attachment, "steer")

    assert :sys.get_state(owner).durable.steer == %{}
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1
  end

  test "a run deadline waits in arrival order and does not cancel its worker early" do
    {fixture, session, attachment} = fixture(script: [%{hold: self(), text: "late reply"}])

    assert {:accepted, "prompt"} =
             Loopex.command(attachment, Map.put(prompt("prompt"), :bounds, %{deadline_ms: 2_000}))

    assert_receive {:holding, model}, 5_000
    owner = coordinator(fixture)
    run = :sys.get_state(owner).durable.active_run_id
    arm(fixture, "steer", :hold)

    assert {:error, :commit_unknown} =
             Loopex.command(attachment, %{
               type: :steer,
               command_id: "steer",
               run_id: run,
               content: "queued instruction"
             })

    assert_receive {:resolution_held, resolver, _}, 5_000

    await(fn ->
      Enum.any?(:queue.to_list(:sys.get_state(owner).unknown_admission.deferred), fn
        {:run_deadline, ^run, _deadline} -> true
        _other -> false
      end)
    end)

    assert Process.alive?(model)

    refute Enum.any?(
             Fixture.records(fixture, session),
             &(&1.payload.kind == "model_termination_admitted_v1")
           )

    send(model, :release)
    await_worker_result(owner, :model)
    send(resolver, :release)
    terminal = finish(attachment)
    assert terminal["outcome"] == "bound_reached"
    assert terminal["bound"] == "deadline"
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1
    assert Agent.get(fixture.executor, & &1.jobs) == []
  end

  test "owner loss joins the resolver and a recreated owner reports absent facts pending" do
    {fixture, session, attachment} = fixture(script: [%{text: "done"}])
    arm(fixture, "unknown", :hold)
    assert {:error, :commit_unknown} = Loopex.command(attachment, prompt("unknown"))
    assert_receive {:resolution_held, resolver, _}, 5_000
    owner = coordinator(fixture)
    owner_monitor = Process.monitor(owner)
    resolver_monitor = Process.monitor(resolver)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, _}, 5_000
    assert_receive {:DOWN, ^resolver_monitor, :process, ^resolver, _}, 5_000
    assert {:error, :owner_unavailable} = Loopex.command_disposition(attachment, "unknown")
    pass(fixture)
    assert {:ok, ^session} = Loopex.resume_session(fixture.runtime, session, command_id: "resume")
    assert {:ok, resumed} = Loopex.attach(fixture.runtime, session, after_event_sequence: 0)

    assert {:ok, {:pending, nil, :commit_unknown, nil}} =
             Loopex.command_disposition(resumed, "unknown")

    assert AgentLoopTestModel.dispatched(fixture.model) == []
    assert length(calls(fixture)) == 3
  end

  test "an executor receipt is deferred behind abort and retained once before cleanup" do
    {fixture, session, attachment} =
      fixture(
        script: [
          %{text: "write", calls: [%{id: "write-1", name: "write", arguments: %{"path" => "a"}}]}
        ],
        tool_progress_gate: self()
      )

    assert {:accepted, "prompt"} = Loopex.command(attachment, prompt("prompt"))
    assert_receive {:tool_progress_emitted, "write-1", executor}, 5_000
    arm(fixture, "abort", :hold)

    assert {:error, :commit_unknown} =
             Loopex.command(attachment, %{type: :abort, command_id: "abort"})

    assert_receive {:resolution_held, resolver, _}, 5_000
    send(executor, :release)
    await_worker_result(coordinator(fixture), :executor)

    refute Enum.any?(
             Fixture.records(fixture, session),
             &(&1.payload.kind == "executor_receipt_committed_v2")
           )

    send(resolver, :release)
    assert finish(attachment)["outcome"] == "cancelled"

    assert Enum.count(
             Fixture.records(fixture, session),
             &(&1.payload.kind == "executor_receipt_committed_v2")
           ) == 1

    assert Enum.count(Fixture.events(fixture, session), &(&1.kind == "tool.finished")) == 1
    assert length(Agent.get(fixture.executor, & &1.jobs)) == 1
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1
  end

  test "an expired admission releases deferred work into the existing mutation fence" do
    {fixture, session, attachment} =
      fixture(
        cleanup_grace_ms: 1,
        script: [%{hold: self(), text: "deferred"}]
      )

    assert {:accepted, "prompt"} = Loopex.command(attachment, prompt("prompt"))
    assert_receive {:holding, model}, 5_000
    owner = coordinator(fixture)
    run = :sys.get_state(owner).durable.active_run_id
    arm(fixture, "steer", :hold_second)

    assert {:error, :commit_unknown} =
             Loopex.command(attachment, %{
               type: :steer,
               command_id: "steer",
               run_id: run,
               content: "unproved"
             })

    assert_receive {:resolution_held, resolver, _}, 5_000
    cutoff = :sys.get_state(owner).unknown_admission.deadline
    resolver_monitor = Process.monitor(resolver)
    owner_monitor = Process.monitor(owner)
    send(model, :release)
    await_worker_result(owner, :model)
    assert_receive {:DOWN, ^resolver_monitor, :process, ^resolver, _}, 25_000
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, _}, 5_000
    assert System.monotonic_time(:millisecond) >= cutoff
    assert {:error, :owner_unavailable} = Loopex.command_disposition(attachment, "steer")
    assert length(calls(fixture)) == 2

    refute Enum.any?(Fixture.records(fixture, session), fn record ->
             String.starts_with?(record.payload.kind, "model_attempt_settled_") or
               record.payload.kind == "run_terminal_committed" or
               record.payload["command_id"] == "steer"
           end)

    assert Agent.get(fixture.executor, & &1.jobs) == []
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1
  end

  test "resource admission retains its internal transaction and public command identity separately" do
    manifest = %{
      version: "loopex.resource_pack/1",
      workspace_ref: "workspace-ref",
      revision: nil,
      packs: [
        %{
          source_id: "project",
          origin: nil,
          commit: nil,
          tree_digest: nil,
          name: "guide",
          description: "guide",
          manual_only: true,
          files: [
            %{
              label: "SKILL.md",
              content: "guide",
              size: 5,
              digest: LoopexProtocol.Canonical.digest_bytes("guide"),
              contained: true
            }
          ]
        }
      ]
    }

    {:ok, digest, _} = Loopex.ResourcePack.digest(manifest)
    {fixture, session, attachment} = fixture(script: [], resource_manifest: manifest)
    command_id = "resource"
    arm(fixture, command_id, :hold_second)

    command = %{
      type: :admit_resources,
      command_id: command_id,
      manifest_digest: digest,
      decision: %{
        manifest_digest: digest,
        workspace_ref: "workspace-ref",
        trust_scope: "project_skills",
        decision_source: "host_supplied",
        issued_at: "2026-09-10T00:00:00Z",
        expires_at: nil,
        revocation_state: "active"
      }
    }

    assert {:error, :commit_unknown} = Loopex.command(attachment, command)
    assert_receive {:resolution_held, resolver, original}, 5_000
    refute original.tx_id == command_id
    assert :sys.get_state(coordinator(fixture)).unknown_admission.command_id == command_id
    send(resolver, :release)

    await(fn ->
      Loopex.command_disposition(attachment, command_id) ==
        {:ok, {:committed, :admitted, :accepted, nil}}
    end)

    assert {:accepted, ^command_id} = Loopex.command(attachment, command)
    assert length(calls(fixture)) == 2
    assert Enum.all?(calls(fixture), &(&1.transaction == original))

    assert Enum.count(
             Fixture.records(fixture, session),
             &(&1.payload.kind == "resource_command_v1")
           ) == 1

    assert AgentLoopTestModel.dispatched(fixture.model) == []
  end
end
