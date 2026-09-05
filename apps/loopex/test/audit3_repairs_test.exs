Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)

defmodule Loopex.Audit3HoldingStore do
  @moduledoc false

  # Concept: a store that can be told to hold exactly the one-row page Control
  # reads while it is authorizing a provider attempt.
  #
  # Technical depth: the hole this exists to observe is real time passing
  # *inside* the dispatch handler, between the deadline check and the send. Only
  # the binding read can take that time, and it is the only `load_records` call
  # in the runtime that asks for a single record -- replay and recovery page in
  # `@page_size` records -- so the limit selects it without the store having to
  # know why it is being called. One arming holds one such read: the caller is
  # named to the observer and waits to be released, so the case decides how long
  # the read takes instead of racing a sleep against it.

  @behaviour Loopex.Store

  alias Loopex.Store

  def start_link do
    Agent.start_link(fn -> nil end)
  end

  def arm(holder, observer), do: Agent.update(holder, fn _state -> observer end)

  @impl Store
  def transact({store, _holder}, transaction), do: Store.transact(store, transaction)

  @impl Store
  def transaction_status({store, _holder}, session_id, mutation_domain, tx_id),
    do: Store.transaction_status(store, session_id, mutation_domain, tx_id)

  @impl Store
  def runtime_command({store, _holder}, command), do: Store.runtime_command(store, command)

  @impl Store
  def ownership_head({store, _holder}, session_id, mutation_domain),
    do: Store.ownership_head(store, session_id, mutation_domain)

  @impl Store
  def load_records({store, holder}, session_id, after_version, limit) do
    if limit == 1, do: hold(holder)
    Store.load_records(store, session_id, after_version, limit)
  end

  @impl Store
  def load_events({store, _holder}, session_id, after_sequence, limit),
    do: Store.load_events(store, session_id, after_sequence, limit)

  defp hold(holder) do
    case Agent.get_and_update(holder, fn observer -> {observer, nil} end) do
      nil ->
        :ok

      observer ->
        send(observer, {:audit3_position_read_held, self()})

        receive do
          :audit3_release -> :ok
        after
          15_000 -> :ok
        end
    end
  end
end

defmodule Loopex.Audit3RepairsTest do
  @moduledoc """
  Drafted regression cases for the third audit's two runtime findings: a permit
  sent after the committed deadline, and a superseded coordinator left alive by
  a cleanup its own supersession made unanswerable.
  """

  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.AgentLoopTestModel
  alias Loopex.Audit3HoldingStore
  alias Loopex.M1RuntimeTestStore
  alias Loopex.Runtime
  alias Loopex.Store

  # Concept: the authority a permit is sent under has to still be authority at
  # the instant of the send.
  #
  # Technical depth: Control checks the deadline, reads the attempt-open row back
  # from the Store, and only then spends the identity and sends the permit. With
  # the deadline established once, before that read, a run with a few hundred
  # milliseconds of authority left and a read that took longer than that was
  # still handed a permit -- and the worker, which deliberately carries no bound
  # of its own, called the provider under expired authority. Here the read is
  # held past the committed deadline while every earlier check passed, so only a
  # deadline re-established after the read can refuse it. Deleting the last
  # `provider_before_deadline/1` clause from the dispatch handler fails exactly
  # this case: the model adapter is entered and the attempt settles dispatched.
  test "a binding read that outlives the committed deadline refuses the permit" do
    {fixture, holder} = start_held(script: [%{text: "done", calls: []}])
    :ok = Audit3HoldingStore.arm(holder, self())

    {session_id, attachment, _reply} = Fixture.run(fixture, "go", %{deadline_ms: 400})

    assert_receive {:audit3_position_read_held, reader},
                   5_000,
                   "Control never read the attempt-open row while authorizing the attempt"

    # Longer than the run's whole remaining authority and well inside Control's
    # own read bound, so the read answers and the refusal can only come from the
    # clock.
    Process.sleep(600)
    send(reader, :audit3_release)

    events = drain(attachment)

    assert AgentLoopTestModel.dispatched(fixture.model) == [],
           "a permit reached the worker after the committed deadline had elapsed"

    settlements = settlements(fixture, session_id)

    assert [{1, "not_dispatched", "deadline"} | _rest] = settlements,
           "the elapsed-deadline refusal did not settle as an exact pre-transport " <>
             "not_dispatched: #{inspect(settlements)}"

    assert Enum.find(events, &(&1.kind == "run.finished"))["outcome"] == "bound_reached"
  end

  # Concept: a store that does not answer is not a verdict about the row.
  #
  # Technical depth: `Store.load_records/4` runs the adapter in the calling
  # process and the shipped local store answers under a thirty-second GenServer
  # call timeout, so an unanswering store held Control -- the runtime-wide
  # ownership serialization point -- for that whole timeout while a provider
  # attempt's authority drained. The read is bounded now, and an exhausted bound
  # refuses exactly as an unreadable row does. The run deadline here is the
  # default ten minutes, so the deadline cannot be what refuses this attempt.
  test "a binding read that never answers inside its bound refuses without holding Control" do
    {fixture, holder} = start_held(script: [%{text: "done", calls: []}])
    :ok = Audit3HoldingStore.arm(holder, self())

    {session_id, attachment, _reply} = Fixture.run(fixture, "go")

    assert_receive {:audit3_position_read_held, reader}, 5_000

    started = System.monotonic_time(:millisecond)
    events = drain(attachment, 20_000)
    elapsed = System.monotonic_time(:millisecond) - started

    # The holder answers after fifteen seconds if nothing releases it, which is
    # what an unbounded read costs Control. Bounded, the attempt is refused
    # about a second in and ADR 0018's one retry -- whose own read is no longer
    # held -- carries the run.
    assert elapsed < 5_000,
           "the run waited #{elapsed}ms on a store read that never answered"

    send(reader, :audit3_release)

    assert [{1, "not_dispatched", nil} | _rest] = settlements(fixture, session_id),
           "an unreadable binding did not settle as an exact pre-transport not_dispatched"

    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1,
           "the refused attempt reached the provider, or its one retry did not"

    assert Enum.find(events, &(&1.kind == "run.finished"))["outcome"] == "completed"
  end

  # Concept: a private Store reader cannot outlive the Control whose authority
  # requested the read.
  #
  # Technical depth: the holding store positively names the exact process blocked
  # inside `load_records/4`. Killing Control before its one-second timer can fire
  # removes the caller that used to own that timeout; an unguarded reader would
  # therefore remain blocked for the store's fifteen-second allowance. The
  # guardian monitors Control independently and kills and awaits this exact
  # reader, so the assertion does not infer cleanup from a later runtime result.
  test "a blocked binding reader dies with its Control" do
    {fixture, holder} = start_held(script: [%{text: "done", calls: []}])
    :ok = Audit3HoldingStore.arm(holder, self())
    {:ok, %{control: control}} = Runtime.children(fixture.runtime)

    {_session_id, _attachment, _reply} = Fixture.run(fixture, "go")

    assert_receive {:audit3_position_read_held, reader},
                   5_000,
                   "Control never entered the held Store read"

    control_monitor = Process.monitor(control)
    reader_monitor = Process.monitor(reader)
    Process.exit(control, :kill)

    assert_receive {:DOWN, ^control_monitor, :process, ^control, :killed}, 1_000

    assert_receive {:DOWN, ^reader_monitor, :process, ^reader, :killed},
                   1_000,
                   "the blocked Store caller survived the Control that requested its read"
  end

  # Concept: a read that answers inside both bounds still dispatches.
  #
  # Technical depth: the negative cases above are only meaningful beside this
  # one. The same held read, released immediately, must leave the ordinary
  # dispatch untouched -- otherwise a bound that refused everything would pass
  # them both.
  test "a binding read that answers in time still dispatches the permit" do
    {fixture, holder} = start_held(script: [%{text: "done", calls: []}])
    :ok = Audit3HoldingStore.arm(holder, self())

    {session_id, attachment, _reply} = Fixture.run(fixture, "go")

    assert_receive {:audit3_position_read_held, reader}, 5_000
    send(reader, :audit3_release)

    events = drain(attachment)

    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1,
           "the attempt was refused even though its binding read answered in time"

    assert settlements(fixture, session_id) == [{1, "dispatched_or_unknown", nil}]
    assert Enum.find(events, &(&1.kind == "run.finished"))["outcome"] == "completed"
  end

  # Concept: a superseded coordinator waiting on a worker it killed itself waits
  # forever, and never gives its session's last generation back.
  #
  # Technical depth: an abort admitted against an open provider attempt records
  # the run in `pending_cleanup` and waits inside a model reserve for the
  # attempt's own answer. Supersession then terminates that worker -- correctly:
  # a model call has no host effect to reconcile -- but left the entry behind.
  # The reserve expired against an absent worker and settled nothing, and the
  # owner-loss reaper refused to stop while `pending_cleanup` was non-empty. The
  # predecessor process, and Control's monitor of it, leaked once per succession
  # over a terminating attempt. `terminate_superseded_effect_free_work/1` now
  # abandons the cleanup it made unanswerable, so the reaper's condition becomes
  # true; the successor still owns the durable disposition of the attempt.
  test "a superseded coordinator is reaped after supersession kills its terminating model worker" do
    fixture = Fixture.start(script: [%{text: "done", calls: [], hold: self()}])
    on_exit(fn -> Fixture.stop(fixture) end)

    {session_id, attachment, _reply} = Fixture.run(fixture, "go")
    assert_receive {:holding, model}, 5_000

    predecessor = coordinator_of(fixture.runtime)
    predecessor_reference = Process.monitor(predecessor)
    model_reference = Process.monitor(model)

    assert {:accepted, "abort-1"} =
             Loopex.command(attachment, %{type: :abort, command_id: "abort-1"})

    held = await_pending_cleanup(predecessor)

    assert map_size(held.pending_cleanup) == 1,
           "the abort did not leave the terminating attempt in pending cleanup"

    assert map_size(held.model_reserves) == 1,
           "the terminating attempt was not waiting inside a model reserve"

    assert {:ok, ^session_id} =
             Loopex.resume_session(fixture.runtime, session_id, command_id: "resume-1")

    assert_receive {:DOWN, ^model_reference, :process, ^model, _reason},
                   5_000,
                   "supersession left the effect-free model worker running"

    # The reaping bound is the succession itself: the predecessor owns no live
    # evidence-producing work the moment its model worker is gone. The model
    # reserve is far longer than this, so a coordinator still waiting on the
    # entry that reserve belongs to is exactly the leak.
    assert_receive {:DOWN, ^predecessor_reference, :process, ^predecessor, :normal},
                   2_500,
                   "the superseded predecessor was never reaped: " <>
                     inspect(
                       Map.take(:sys.get_state(predecessor), [
                         :in_flight,
                         :pending_cleanup,
                         :model_reserves,
                         :executor_reserves,
                         :streams
                       ])
                     )

    # The successor, not the reaped predecessor, owns the durable disposition of
    # the inherited attempt, and it does not call the provider again. The
    # predecessor's attachment went stale with its owner, so the run is read
    # through the successor's.
    {:ok, resumed} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)
    events = drain(resumed)

    # The attempt the successor inherits was open and possibly billed, so ADR
    # 0018 recovers it as owner loss: charged, terminal, never retried. The run
    # ends `outcome_unknown` rather than `cancelled` because that unprovable
    # attempt outranks the abort that asked the run to stop.
    assert Enum.find(events, &(&1.kind == "run.finished"))["outcome"] == "outcome_unknown"

    assert settlements(fixture, session_id) == [],
           "the reaped predecessor committed a settlement under a stale epoch"

    assert [%{payload: terminal, owner_epoch: successor_epoch}] =
             fixture
             |> Fixture.records(session_id)
             |> Enum.filter(&(&1.payload[:kind] == "run_terminal_committed"))

    assert successor_epoch == 2, "the terminal was not committed by the successor"
    assert terminal["outcome"] == "outcome_unknown"
    assert terminal["command_id"] == "abort-1"
    assert is_binary(terminal["reconciliation_ref"])

    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1,
           "the successor called the provider again for the attempt it inherited"
  end

  # Concept: a reserve belonging to an owner that has lost the session ends that
  # owner's wait; it never decides what the wait was waiting for.
  #
  # Technical depth: the sibling `{:run_deadline, …}` handler refuses to act
  # after supersession because the successor owns the decision, and the reserve
  # handlers carried no such guard. Relying on the Store fence to refuse the
  # settlement that follows is not the same thing: the settlement path first
  # terminates a worker, disarms timers and closes a stream, and only its
  # ownership refusals are classified -- any other refusal stops the coordinator
  # abnormally. The reserve here is installed directly because supersession now
  # cancels the one it can see; this is the slice that was already in the
  # mailbox. The guarded branch abandons the wait, so the reaper's condition
  # becomes true, and the session's records are untouched.
  test "a model reserve firing after supersession settles nothing and releases the owner" do
    fixture = Fixture.start(script: [%{text: "done", calls: []}])
    on_exit(fn -> Fixture.stop(fixture) end)

    {session_id, attachment, _reply} = Fixture.run(fixture, "go")
    assert Enum.find(drain(attachment), &(&1.kind == "run.finished"))["outcome"] == "completed"

    predecessor = coordinator_of(fixture.runtime)
    predecessor_reference = Process.monitor(predecessor)
    records_before = Fixture.records(fixture, session_id)
    run_id = "queued-model-cleanup"

    :sys.replace_state(predecessor, fn state ->
      %{
        state
        | pending_cleanup: Map.put(state.pending_cleanup, run_id, %{purpose: :abort, model: nil}),
          model_reserves: Map.put(state.model_reserves, run_id, make_ref())
      }
    end)

    GenServer.cast(predecessor, {:superseded, "replacement-generation"})

    refute_receive {:DOWN, ^predecessor_reference, :process, ^predecessor, _reason},
                   200,
                   "owner loss reaped the coordinator before its pending cleanup was settled"

    send(predecessor, {:model_reserve, run_id, System.monotonic_time(:millisecond) - 1})

    assert_receive {:DOWN, ^predecessor_reference, :process, ^predecessor, :normal},
                   2_000,
                   "the expiring reserve neither settled its cleanup nor released the owner"

    assert Fixture.records(fixture, session_id) == records_before,
           "a superseded owner committed a record from an expiring model reserve"
  end

  # Concept: the same guard, and the one difference an effect makes -- a
  # superseded owner must not kill the worker holding an operation's receipt.
  #
  # Technical depth: expiry stops the executor task and settles the run on
  # whatever it had produced. Under supersession the Store fence would refuse
  # that commit, but only after the worker was already dead for a bound its
  # successor never agreed to, and ADR 0014 keeps an effectful worker alive
  # until it answers precisely so its receipt survives the handoff. The guarded
  # branch therefore kills nothing and settles nothing, and the predecessor
  # stays alive exactly as long as it owns that evidence-producing work.
  test "an executor reserve firing after supersession kills no effectful worker" do
    fixture =
      Fixture.start(
        script: [
          %{text: "call", calls: [%{id: "c1", name: "write", arguments: %{"path" => "c1"}}]},
          %{text: "done", calls: []}
        ],
        tool_delay_ms: 30_000
      )

    on_exit(fn -> Fixture.stop(fixture) end)

    {session_id, attachment, _reply} = Fixture.run(fixture, "go")

    predecessor = coordinator_of(fixture.runtime)
    predecessor_reference = Process.monitor(predecessor)

    # The abort has to land while the job is genuinely running: an abort before
    # dispatch has no effect to wait for and opens no reserve at all.
    assert await_executor_in_flight(predecessor),
           "the tool call never reached the executor"

    assert {:accepted, "abort-1"} =
             Loopex.command(attachment, %{type: :abort, command_id: "abort-1"})

    reserve = await_executor_reserve(predecessor)
    assert [{_run_id, %{pid: worker}}] = Map.to_list(reserve)
    worker_reference = Process.monitor(worker)

    {:ok, %{execute_result_reserve_ms: reserve_ms}} =
      Loopex.Executor.cancellation_bounds(5_000)

    assert {:ok, ^session_id} =
             Loopex.resume_session(fixture.runtime, session_id, command_id: "resume-1")

    refute_receive {:DOWN, ^worker_reference, :process, ^worker, _reason},
                   reserve_ms + 1_000,
                   "a superseded owner killed the worker holding the operation's receipt"

    assert Process.alive?(predecessor),
           "the predecessor left while it still owned evidence-producing executor work"

    refute_receive {:DOWN, ^predecessor_reference, :process, ^predecessor, _reason}, 0

    assert fixture
           |> Fixture.records(session_id)
           |> Enum.filter(&(&1.payload[:kind] == "run_terminal_committed"))
           |> Enum.filter(&(&1.owner_epoch == 1)) == [],
           "the superseded predecessor committed a run terminal from its expired reserve"
  end

  defp await_executor_in_flight(coordinator, attempts \\ 300) do
    in_flight = :sys.get_state(coordinator).in_flight

    running? =
      Enum.any?(in_flight, fn
        {_reference, {:executor, _run_id, _pid}} -> true
        _other -> false
      end)

    cond do
      running? -> true
      attempts == 0 -> false
      true -> Process.sleep(10) && await_executor_in_flight(coordinator, attempts - 1)
    end
  end

  defp await_executor_reserve(coordinator, attempts \\ 300) do
    state = :sys.get_state(coordinator)

    cond do
      map_size(state.executor_reserves) > 0 -> state.executor_reserves
      attempts == 0 -> state.executor_reserves
      true -> Process.sleep(10) && await_executor_reserve(coordinator, attempts - 1)
    end
  end

  defp start_held(options) do
    fixture = Fixture.start(options)
    :ok = Loopex.stop(fixture.runtime)

    {:ok, holder} = Audit3HoldingStore.start_link()
    {:ok, backing} = Store.new(M1RuntimeTestStore, fixture.store)
    {:ok, store} = Store.new(Audit3HoldingStore, {backing, holder})

    {:ok, runtime} =
      Loopex.start_link(
        context_token_budget: 8_192,
        runtime_id: "audit3-#{System.unique_integer([:positive])}",
        store: store,
        model: %{
          module: AgentLoopTestModel,
          model: "scripted:v1",
          options: [script: fixture.model, max_tokens: 256]
        },
        executor: %{
          module: Loopex.AgentLoopTestExecutor,
          reference: fixture.executor,
          identity: "agent-loop-executor",
          epoch: 1,
          fencing_token: 1,
          workspace_ref: "workspace-ref",
          workspace_lease: "workspace-lease"
        },
        tool: nil,
        bounds: %{max_turns: 8, token_budget: 1_000_000, deadline_ms: 600_000},
        tools: fixture.definitions,
        active_tools: Enum.map(fixture.definitions, &Map.fetch!(&1, "tool_id")),
        policy: Loopex.AgentLoopTestPolicy,
        grant_decision: {:host_policy, :allow}
      )

    fixture = %{fixture | runtime: runtime}
    on_exit(fn -> Fixture.stop(fixture) end)

    {fixture, holder}
  end

  defp settlements(fixture, session_id) do
    fixture
    |> Fixture.records(session_id)
    |> Enum.filter(&(&1.payload[:kind] == "model_attempt_settled_v1"))
    |> Enum.map(&{&1.payload["attempt"], &1.payload["transport"], &1.payload["termination"]})
  end

  defp await_pending_cleanup(coordinator, attempts \\ 100) do
    state = :sys.get_state(coordinator)

    cond do
      map_size(state.pending_cleanup) > 0 -> state
      attempts == 0 -> state
      true -> Process.sleep(10) && await_pending_cleanup(coordinator, attempts - 1)
    end
  end

  defp coordinator_of(runtime) do
    {:ok, children} = Loopex.Runtime.Supervisor.children(runtime.supervisor)

    [{_id, pid, _type, _modules} | _rest] = DynamicSupervisor.which_children(children.sessions)
    pid
  end

  defp drain(attachment, deadline_ms \\ 15_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    collect(attachment, deadline, deadline_ms, [])
  end

  defp collect(attachment, deadline, deadline_ms, acc) do
    case Loopex.next_event(attachment) do
      {:ok, event} ->
        acc = [event | acc]

        if event.kind == "run.finished",
          do: Enum.reverse(acc),
          else: collect(attachment, deadline, deadline_ms, acc)

      other ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("""
          no run.finished within #{deadline_ms}ms.
          last read: #{inspect(other)}
          events observed: #{inspect(Enum.map(Enum.reverse(acc), & &1.kind))}
          """)
        else
          Process.sleep(10)
          collect(attachment, deadline, deadline_ms, acc)
        end
    end
  end
end
