Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)

defmodule Loopex.TelemetryBoundaryTest do
  @moduledoc """
  ## Concept

  The diagnostics plane the trace tracer and the telemetry handler share is
  bounded: however many senders race, the dispatcher's backlog cannot exceed
  the runtime's ceiling, a sender that cannot claim a slot drops its own item
  and counts the drop, and what was lost is reported exactly once the backlog
  drains.

  ## Technical depth

  These cases drive the real admission path of a real runtime rather than a
  copy of it. The dispatcher is suspended to hold the backlog still while
  senders race, which is what makes the ceiling observable: with the dispatcher
  draining, a bound on the instantaneous backlog cannot be read off the
  mailbox. Crash cuts are placed between the same steps production uses -- the
  ticket, the claim, the send -- so what a killed sender holds afterwards is
  the real consequence of dying there.
  """

  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture
  alias Loopex.Instrumentation
  alias Loopex.M1RuntimeTestStore, as: TestStore
  alias Loopex.Runtime
  alias Loopex.Runtime.DiagnosticsAdmission, as: Admission

  @ceiling 8

  test "an uninstrumented build pays a bounded cost and gets its result back unchanged" do
    # Nothing is listening, which is what a host that attached no handler has.
    assert :telemetry.list_handlers([:loopex, :store, :transact, :stop]) == []

    rounds = 10_000
    started = System.monotonic_time(:millisecond)

    outcome =
      Enum.reduce(1..rounds, 0, fn index, total ->
        {:ok, value} =
          Instrumentation.span([:store, :transact], %{session_id: "s_1", records: 1}, fn ->
            {:ok, index}
          end)

        total + value
      end)

    elapsed = System.monotonic_time(:millisecond) - started

    # The result of the work crosses the span untouched, every time.
    assert outcome == div(rounds * (rounds + 1), 2)

    # Two `:telemetry` dispatches over an empty handler list, ten thousand
    # times. The bound is generous enough to survive a loaded machine and small
    # enough to fail if a span ever starts doing work of its own.
    assert elapsed < 2_000,
           "#{rounds} spans with no handler attached took #{elapsed}ms"
  end

  test "the coordinator cuts emit spans for one prompt, naming the run and never its words" do
    handler = {__MODULE__, :cut_spans, make_ref()}
    parent = self()

    :ok =
      :telemetry.attach_many(
        handler,
        [
          [:loopex, :command, :admit, :stop],
          [:loopex, :commit, :stop],
          [:loopex, :events, :publish, :stop],
          [:loopex, :model, :complete, :stop]
        ],
        fn event, measurements, metadata, _config ->
          send(parent, {:span, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    fixture = AgentLoopFixture.start(script: [%{text: "done", calls: []}])
    on_exit(fn -> AgentLoopFixture.stop(fixture) end)

    {:ok, session_id} = Loopex.create_session(fixture.runtime, %{}, command_id: "cs")
    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)

    assert {:accepted, "p1"} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "p1",
               content: "the task nobody may read here"
             })

    assert_receive {:span, [:loopex, :command, :admit, :stop], measured, admitted}, 5_000
    assert is_integer(measured.duration)
    assert admitted.session_id == session_id
    assert admitted.command_id == "p1"
    assert admitted.type == :prompt
    assert admitted.outcome == :accepted

    assert_receive {:span, [:loopex, :commit, :stop], _committed_measured, committed}, 5_000
    assert committed.session_id == session_id
    assert committed.kind == :session_commit
    assert committed.outcome == :committed

    assert_receive {:span, [:loopex, :events, :publish, :stop], _published_measured, published},
                   5_000

    assert published.session_id == session_id
    assert is_integer(published.event_sequence)
    assert is_integer(published.journal_version)

    assert_receive {:span, [:loopex, :model, :complete, :stop], _model_measured, model}, 5_000
    assert model.session_id == session_id
    assert is_binary(model.run_id)
    assert model.attempt == 1

    # No cut carried the operator's words, the staged request, or the reply.
    for metadata <- [admitted, committed, published, model] do
      rendered = inspect(metadata, limit: :infinity)
      refute rendered =~ "the task nobody may read here"
      refute rendered =~ "done"
    end
  end

  test "instrumented port callbacks emit start stop spans carrying identities and no content" do
    handler = {__MODULE__, :port_spans, make_ref()}
    parent = self()

    :ok =
      :telemetry.attach_many(
        handler,
        [
          [:loopex, :store, :transact, :start],
          [:loopex, :store, :transact, :stop],
          [:loopex, :store, :load_events, :stop]
        ],
        fn event, measurements, metadata, _config ->
          send(parent, {:span, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    %{runtime: runtime} = fixture()
    {:ok, session_id} = Loopex.create_session(runtime, %{}, command_id: "instrumented")
    {:ok, _attachment} = Loopex.attach(runtime, session_id, after_event_sequence: 0)

    assert_receive {:span, [:loopex, :store, :transact, :start], start_measurements, _metadata},
                   2_000

    assert is_integer(start_measurements.monotonic_time)

    assert_receive {:span, [:loopex, :store, :transact, :stop], measurements, metadata}, 2_000
    assert is_integer(measurements.duration)
    assert metadata.type == :create_session
    assert metadata.records == 1
    assert metadata.outcome == :committed

    # The span carries what happened and to which session, and nothing about
    # what the rows say.
    rendered = inspect(metadata, limit: :infinity)
    refute rendered =~ "payload"
    refute rendered =~ "canonical_request_bytes"

    assert_receive {:span, [:loopex, :store, :load_events, :stop], _measured, read_metadata},
                   2_000

    assert read_metadata.session_id == session_id
    assert Map.has_key?(read_metadata, :limit)
    assert read_metadata.outcome == :ok
  end

  test "racing senders claim a slot with one atomic owner recording insert before sending so the backlog never exceeds the ceiling and drops are counted without a send" do
    %{runtime: runtime, dispatcher: dispatcher, admission: admission} = fixture()

    # With the dispatcher suspended nothing is released, so the backlog is the
    # number of claims that succeeded and the ceiling is observable.
    :ok = :sys.suspend(dispatcher)

    senders = 64
    results = race(admission, senders)

    admitted = Enum.count(results, &(&1 == :ok))
    dropped = Enum.count(results, &(&1 == :dropped))

    assert admitted == @ceiling
    assert dropped == senders - @ceiling
    assert Admission.held(admission) == @ceiling
    assert Admission.pending_drops(admission) == dropped
    # The bound is on admitted items. A sender also registers itself for
    # monitoring once, and those registrations are one per live sender rather
    # than per item, so they are counted separately here.
    assert admitted_in_mailbox(dispatcher) == @ceiling

    :ok = :sys.resume(dispatcher)

    # Everything admitted is delivered, and nothing dropped was ever sent.
    delivered = drain(admitted)
    assert length(delivered) == admitted
    assert Enum.all?(delivered, &(&1["kind"] == "admission_probe"))

    assert Runtime.alive?(runtime)
  end

  test "a sender killed at each crash cut after taking a ticket after a failed claim after a successful claim and after the send holds afterwards exactly its claimed but unsent slots released at its DOWN while a concurrent sender's slot stays live and admits and a release frees only the exact claim it names" do
    %{dispatcher: dispatcher, admission: admission} = fixture()
    :ok = :sys.suspend(dispatcher)

    # A live sender's slot, claimed before every crash cut below and still held
    # after each one: no reconciliation may touch it.
    live = start_sender(admission)
    {:ok, live_slot, live_ticket} = sender_step(live, :claim)
    assert owner(admission, live_slot) == {live, live_ticket}

    # Each cut is taken in turn, and the case is written as five calls rather
    # than a comprehension because a comprehension inside a test with a name
    # this long generates a function name past the atom limit.
    state = %{admission: admission, dispatcher: dispatcher, slot: live_slot}
    crash_cut(state, :before_register, {live, live_ticket})
    crash_cut(state, :after_ticket, {live, live_ticket})
    crash_cut(state, :after_failed_claim, {live, live_ticket})
    crash_cut(state, :after_claim, {live, live_ticket})
    crash_cut(state, :after_send, {live, live_ticket})

    :ok = :sys.resume(dispatcher)

    # A release names an exact claim: releasing a triple that no longer matches
    # frees nothing, and the live sender's slot survives it.
    :ok = Admission.release(admission, live_slot, live, live_ticket + 1)
    assert owner(admission, live_slot) == {live, live_ticket}
    :ok = Admission.release(admission, live_slot, live, live_ticket)
    assert owner(admission, live_slot) == nil

    # With its slot free, that slot admits again.
    assert send_one(live) == :ok
  end

  test "the drain summary carries the exact number of counted drops taken by one atomic exchange" do
    %{dispatcher: dispatcher, admission: admission} = fixture()
    :ok = :sys.suspend(dispatcher)

    senders = 40
    results = race(admission, senders)
    dropped = Enum.count(results, &(&1 == :dropped))
    assert dropped == senders - @ceiling

    :ok = :sys.resume(dispatcher)

    summary = await_entry("diagnostics_dropped")
    assert summary["dropped"] == dropped
    assert summary["window"]["to_ticket"] >= summary["window"]["from_ticket"]

    # The count was taken, not copied: nothing remains to report.
    assert Admission.pending_drops(admission) == 0
    refute_receive {:loopex_diagnostic, %{"kind" => "diagnostics_dropped"}}, 200
  end

  test "a dead or saturated host sink is discarded and counted rather than bounded" do
    sink = spawn(fn -> Process.sleep(:infinity) end)
    %{dispatcher: dispatcher, admission: admission} = fixture(diagnostics_to: sink)

    Process.exit(sink, :kill)
    await(fn -> not Process.alive?(sink) end)

    assert Admission.admit(admission, %{"kind" => "admission_probe"}) == :ok
    await(fn -> Admission.pending_drops(admission) > 0 or Admission.held(admission) == 0 end)

    # The runtime is unharmed by a sink it cannot reach.
    assert Process.alive?(dispatcher)
  end

  defp fixture(options \\ []) do
    {store_pid, store} = TestStore.start_store()

    {:ok, runtime} =
      Loopex.start_link(
        Keyword.merge(
          [
            context_token_budget: 8_192,
            runtime_id: "diagnostics-admission",
            store: store,
            diagnostics_to: self(),
            diagnostics_ceiling: @ceiling
          ],
          options
        )
      )

    {:ok, %{dispatcher: dispatcher}} = Runtime.children(runtime)
    {:ok, admission} = Runtime.diagnostics_admission(runtime)

    on_exit(fn ->
      resume(dispatcher)
      if Runtime.alive?(runtime), do: Loopex.stop(runtime)
      if Process.alive?(store_pid), do: GenServer.stop(store_pid)
    end)

    %{runtime: runtime, dispatcher: dispatcher, admission: admission}
  end

  # Concept: many senders offering one item each at the same moment.
  #
  # Technical depth: every sender waits for one start message, so the claims
  # race rather than running in the order the processes were spawned.
  defp race(admission, count) do
    parent = self()

    senders =
      for index <- 1..count do
        spawn(fn ->
          receive do
            :go ->
              result =
                Admission.admit(admission, %{"kind" => "admission_probe", "index" => index})

              send(parent, {:admission_result, self(), result})
          end
        end)
      end

    Enum.each(senders, &send(&1, :go))

    Enum.map(senders, fn sender ->
      receive do
        {:admission_result, ^sender, result} -> result
      after
        2_000 -> flunk("a sender never reported its admission result")
      end
    end)
  end

  # Concept: one sender killed at one exact step, and what it holds afterwards.
  #
  # Technical depth: the dispatcher is resumed only to process the `DOWN`, so
  # reconciliation is observed as its own step. The live sender's claim is
  # checked after every cut, because a reconciliation that swept a live
  # sender's slot would still leave the counts right.
  defp crash_cut(state, cut, {live, live_ticket}) do
    %{admission: admission, dispatcher: dispatcher, slot: live_slot} = state
    sender = start_sender(admission)
    held_by_sender = reach_cut(sender, cut, live_slot)

    before_down = Admission.held(admission)
    monitor = Process.monitor(sender)
    Process.exit(sender, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^sender, :killed}, 1_000

    :ok = :sys.resume(dispatcher)
    await_held(admission, before_down - held_by_sender)
    :ok = :sys.suspend(dispatcher)

    assert owner(admission, live_slot) == {live, live_ticket}
  end

  # Concept: drive one sender to the step it is to be killed at, and say how
  # many slots it holds there.
  defp reach_cut(_sender, :before_register, _live_slot), do: 0

  defp reach_cut(sender, :after_ticket, _live_slot) do
    {:ok, _ticket} = sender_step(sender, :ticket)
    0
  end

  # Technical depth: this sender's ticket maps onto the slot the live sender
  # holds, so its claim fails; it counts a drop and holds nothing.
  defp reach_cut(sender, :after_failed_claim, live_slot) do
    {:taken, _ticket} = sender_step(sender, {:claim_colliding, live_slot})
    0
  end

  defp reach_cut(sender, :after_claim, _live_slot) do
    {:ok, _slot, _ticket} = sender_step(sender, :claim)
    1
  end

  defp reach_cut(sender, :after_send, _live_slot) do
    {:ok, _slot, _ticket} = sender_step(sender, :claim_and_send)
    0
  end

  defp start_sender(admission) do
    parent = self()
    spawn(fn -> sender_loop(admission, parent) end)
  end

  defp sender_loop(admission, parent) do
    receive do
      {:step, :ticket} ->
        send(parent, {:stepped, self(), {:ok, Admission.take_ticket(admission)}})
        sender_loop(admission, parent)

      {:step, :claim} ->
        Admission.register(admission)
        ticket = Admission.take_ticket(admission)
        {:ok, slot} = Admission.claim(admission, ticket)
        send(parent, {:stepped, self(), {:ok, slot, ticket}})
        sender_loop(admission, parent)

      {:step, {:claim_colliding, slot}} ->
        Admission.register(admission)
        ticket = colliding_ticket(admission, slot)
        :taken = Admission.claim(admission, ticket)
        Admission.count_drop(admission)
        send(parent, {:stepped, self(), {:taken, ticket}})
        sender_loop(admission, parent)

      {:step, :claim_and_send} ->
        Admission.register(admission)
        ticket = Admission.take_ticket(admission)
        {:ok, slot} = Admission.claim(admission, ticket)
        Admission.deliver(admission, slot, ticket, %{"kind" => "admission_probe"})
        send(parent, {:stepped, self(), {:ok, slot, ticket}})
        sender_loop(admission, parent)

      {:step, :admit} ->
        send(
          parent,
          {:stepped, self(), Admission.admit(admission, %{"kind" => "admission_probe"})}
        )

        sender_loop(admission, parent)
    end
  end

  defp sender_step(sender, step) do
    send(sender, {:step, step})

    receive do
      {:stepped, ^sender, result} -> result
    after
      2_000 -> flunk("the sender never completed #{inspect(step)}")
    end
  end

  defp send_one(sender), do: sender_step(sender, :admit)

  # Concept: a ticket whose slot is the one already held.
  #
  # Technical depth: tickets advance by one, so taking them until the ticket
  # maps onto the wanted slot reaches the collision this cut needs without
  # reaching into the counter.
  defp colliding_ticket(admission, slot) do
    ticket = Admission.take_ticket(admission)
    if rem(ticket, @ceiling) == slot, do: ticket, else: colliding_ticket(admission, slot)
  end

  defp owner(%{slots: slots}, slot) do
    case :ets.lookup(slots, slot) do
      [{^slot, pid, ticket}] -> {pid, ticket}
      [] -> nil
    end
  end

  defp admitted_in_mailbox(pid) do
    {:messages, messages} = Process.info(pid, :messages)
    Enum.count(messages, &admission_message?/1)
  end

  defp admission_message?({:loopex_diagnostic_admission, _pid, _slot, _ticket, _item}), do: true
  defp admission_message?(_message), do: false

  defp drain(expected, collected \\ []) do
    receive do
      {:loopex_diagnostic, entry} -> drain(expected, [entry | collected])
    after
      200 -> Enum.reverse(collected) |> Enum.filter(&(&1["kind"] == "admission_probe"))
    end
  end

  defp await_entry(kind, deadline \\ 2_000) do
    receive do
      {:loopex_diagnostic, %{"kind" => ^kind} = entry} -> entry
      {:loopex_diagnostic, _other} -> await_entry(kind, deadline)
    after
      deadline -> flunk("no #{kind} entry arrived within #{deadline}ms")
    end
  end

  # Concept: wait for the dispatcher to have released what a DOWN freed.
  #
  # Technical depth: this lives in its own function because the case that uses
  # it carries one of the gate's locked witness names, and a closure written
  # inside a test that long generates a function name past the atom limit.
  defp await_held(admission, expected, deadline \\ 2_000) do
    cond do
      Admission.held(admission) == expected ->
        :ok

      deadline <= 0 ->
        flunk("the dispatcher held #{Admission.held(admission)}, not #{expected}")

      true ->
        Process.sleep(20)
        await_held(admission, expected, deadline - 20)
    end
  end

  defp await(condition, deadline \\ 2_000) do
    if condition.() do
      :ok
    else
      if deadline <= 0 do
        flunk("condition never held")
      else
        Process.sleep(20)
        await(condition, deadline - 20)
      end
    end
  end

  defp resume(dispatcher) do
    :sys.resume(dispatcher)
  catch
    :exit, _reason -> :ok
  end
end
