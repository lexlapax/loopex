Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)

defmodule Loopex.ProviderAttemptPageOneStore do
  @moduledoc false

  @behaviour Loopex.Store

  alias Loopex.Store

  @impl Store
  def transact({store, _observer}, transaction), do: Store.transact(store, transaction)

  @impl Store
  def transaction_status({store, _observer}, session_id, mutation_domain, tx_id),
    do: Store.transaction_status(store, session_id, mutation_domain, tx_id)

  @impl Store
  def runtime_command({store, _observer}, command), do: Store.runtime_command(store, command)

  @impl Store
  def ownership_head({store, _observer}, session_id, mutation_domain),
    do: Store.ownership_head(store, session_id, mutation_domain)

  @impl Store
  def load_records({store, observer}, session_id, after_version, _requested_limit) do
    result = Store.load_records(store, session_id, after_version, 1)
    send(observer, {:provider_attempt_record_page, after_version, result})
    result
  end

  @impl Store
  def load_events({store, _observer}, session_id, after_sequence, limit),
    do: Store.load_events(store, session_id, after_sequence, limit)
end

defmodule Loopex.ProviderAttemptExitModel do
  @moduledoc false

  @behaviour Loopex.Model

  @impl Loopex.Model
  def complete(request, options, _progress) do
    observer = Keyword.fetch!(options, :observer)
    send(observer, {:provider_attempt_exit_model_called, self(), request})
    exit(:third_party_model_down)
  end
end

defmodule Loopex.ProviderAttemptProtocolTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.AgentLoopTestModel
  alias Loopex.M1RuntimeTestStore
  alias Loopex.ProviderAttemptPageOneStore
  alias Loopex.Runtime
  alias Loopex.Runtime.ProviderAttempt
  alias Loopex.Runtime.SessionState
  alias Loopex.Store
  alias Loopex.StreamDomain

  @uint64_max 18_446_744_073_709_551_615
  @record_limit 65_536
  @record_depth_limit 12
  @record_cardinality_limit 1_024
  @delivery_ledger :provider_attempt_delivery_ledger

  test "the request and first attempt open atomically before one direct one-use Control permit can invoke the provider" do
    fixture = start(script: [%{text: "done", calls: [], hold: self()}], progress_to: self())
    {:ok, %{control: control}} = Runtime.children(fixture.runtime)
    :erlang.trace(control, true, [:send, :receive])

    :ok =
      M1RuntimeTestStore.hold_next_record_before_linearization(
        fixture.store,
        "model_attempt_opened_v1",
        self()
      )

    {session_id, attachment, {:accepted, "prompt-1"}} = Fixture.run(fixture, "open once")

    assert_receive {:record_held_before_linearization, waiter, _store, "model_attempt_opened_v1",
                    transaction},
                   5_000

    assert Enum.map(transaction.records, &record_kind/1) == [
             "model_request_committed",
             "model_attempt_opened_v1"
           ]

    [request, opened] = transaction.records
    assert opened["attempt"] == 1
    assert opened["run_id"] == request["run_id"]
    assert opened["turn_id"] == request["turn_id"]
    assert opened["operation_id"] == request["operation_id"]
    assert opened["staged_request_digest"] == request["staged_request_digest"]
    refute_receive {:holding, _worker}, 0

    M1RuntimeTestStore.release(waiter)
    assert_receive {:holding, worker}, 5_000

    assert_receive {:trace, ^control, :send, permit, ^worker}, 5_000
    expected_binding = Map.put(attempt_identity(opened), "session_id", session_id)

    permit_binding = coherent_attempt_binding!(permit, expected_binding)
    assert permit_binding == expected_binding

    {caller, request} = await_control_request_binding(control, worker, expected_binding)
    assert caller == coordinator_of(fixture.runtime)
    assert coherent_attempt_binding!(request, expected_binding) == expected_binding

    authority = permit_authority!(fixture, session_id, opened, request, worker)

    assert authority.runtime_id == fixture.runtime_id
    assert authority.session_id == session_id
    assert authority.coordinator == caller
    assert authority.worker == worker
    assert authority.owner_epoch > 0
    assert is_binary(authority.owner_incarnation_id)
    assert authority.journal_version > 0
    assert authority.deadline >= System.system_time(:millisecond)

    [permit_reference] =
      request
      |> references()
      |> MapSet.intersection(references(permit))
      |> MapSet.to_list()

    observer = self()

    fresh_worker =
      spawn(fn ->
        receive do
          message -> send(observer, {:fresh_permit_received, self(), message})
        after
          5_000 -> :ok
        end
      end)

    duplicate_request =
      request
      |> replace_exact(worker, fresh_worker)
      |> replace_exact(permit_reference, make_ref())

    assert {:error, _spent_attempt} = GenServer.call(control, duplicate_request, 5_000)
    refute_receive {:fresh_permit_received, ^fresh_worker, _message}, 0
    refute_receive {:trace, ^control, :send, _second_permit, ^worker}, 0

    send(worker, :release)
    assert await_event(attachment, "run.finished")["outcome"] == "completed"
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1
    :erlang.trace(control, false, [:all])
  end

  test "a second permit request for a spent attempt identity from its own coordinator is refused as already permitted" do
    # Concept: one attempt identity earns one permit, and the refusal of a
    # second request is the one-use linearization itself, not a side effect of
    # ownership.
    #
    # Technical depth: the sibling case above issues its duplicate from the test
    # process, which Control refuses as a non-owner before the one-use check
    # runs, so deleting that check leaves it green. Here the duplicate carries
    # the coordinator's own pid as caller, so ownership, position, worker, and
    # deadline all pass and only the spent-identity check can refuse. The reply
    # is routed to an alias this process owns, so the coordinator never sees a
    # stray message and the exact refusal reason is asserted by name.
    fixture = start(script: [%{text: "done", calls: [], hold: self()}], progress_to: self())
    {:ok, %{control: control}} = Runtime.children(fixture.runtime)
    :erlang.trace(control, true, [:send, :receive])

    {session_id, attachment, {:accepted, "prompt-1"}} = Fixture.run(fixture, "open once")
    assert_receive {:holding, worker}, 5_000
    assert_receive {:trace, ^control, :send, permit, ^worker}, 5_000

    records = Fixture.records(fixture, session_id)
    [opened] = Enum.filter(records, &(&1.payload[:kind] == "model_attempt_opened_v1"))
    expected_binding = Map.put(attempt_identity(opened.payload), "session_id", session_id)
    assert coherent_attempt_binding!(permit, expected_binding) == expected_binding

    {caller, request} = await_control_request_binding(control, worker, expected_binding)
    assert caller == coordinator_of(fixture.runtime)

    [permit_reference] =
      request
      |> references()
      |> MapSet.intersection(references(permit))
      |> MapSet.to_list()

    observer = self()

    fresh_worker =
      spawn(fn ->
        receive do
          message -> send(observer, {:fresh_permit_received, self(), message})
        after
          5_000 -> :ok
        end
      end)

    duplicate_request =
      request
      |> replace_exact(worker, fresh_worker)
      |> replace_exact(permit_reference, make_ref())

    reply_alias = :erlang.alias([:reply])
    send(control, {:"$gen_call", {caller, [:alias | reply_alias]}, duplicate_request})

    assert_receive {[:alias | ^reply_alias], {:error, :provider_attempt_already_permitted}}, 5_000
    refute_receive {:fresh_permit_received, ^fresh_worker, _message}, 0
    refute_receive {:trace, ^control, :send, _second_permit, ^worker}, 0

    send(worker, :release)
    assert await_event(attachment, "run.finished")["outcome"] == "completed"
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1
    :erlang.trace(control, false, [:all])
  end

  test "a dispatch binding that is not the canonical attempt identity is refused, not spent" do
    # Concept: the permit is one-use in the identity it names, so an identity
    # Control did not check is not the identity it spent.
    #
    # Technical depth: Control validated ownership, position, worker, and
    # deadline through `authority`, but took the caller's `binding` map as the
    # spent-permit key after reading only `"session_id"` out of it. A binding
    # carrying an extra member, or naming a different attempt, is a different
    # map and therefore a different key, so it passed the unspent check and was
    # reported dispatched -- a second permit for the same attempt under a
    # different spelling. ADR 0018 requires Control to verify that "every
    # identity equals its registered state" before it spends anything, so the
    # exact six-member binding is validated first.
    fixture = start(script: [%{text: "done", calls: [], hold: self()}], progress_to: self())
    {:ok, %{control: control}} = Runtime.children(fixture.runtime)
    :erlang.trace(control, true, [:send, :receive])

    {session_id, attachment, {:accepted, "prompt-1"}} = Fixture.run(fixture, "open once")
    assert_receive {:holding, worker}, 5_000
    assert_receive {:trace, ^control, :send, permit, ^worker}, 5_000

    records = Fixture.records(fixture, session_id)
    [opened] = Enum.filter(records, &(&1.payload[:kind] == "model_attempt_opened_v1"))
    expected_binding = Map.put(attempt_identity(opened.payload), "session_id", session_id)
    assert coherent_attempt_binding!(permit, expected_binding) == expected_binding

    {caller, request} = await_control_request_binding(control, worker, expected_binding)
    assert caller == coordinator_of(fixture.runtime)
    assert spent_attempt_bindings(control) == [expected_binding]

    [permit_reference] =
      request
      |> references()
      |> MapSet.intersection(references(permit))
      |> MapSet.to_list()

    observer = self()

    tampered = [
      {Map.put(expected_binding, "extra", "member"), :invalid_provider_attempt_binding},
      {Map.delete(expected_binding, "turn_id"), :invalid_provider_attempt_binding},
      {Map.put(expected_binding, "attempt", expected_binding["attempt"] + 1),
       :invalid_provider_attempt_binding},
      {Map.put(expected_binding, "run_id", "run_" <> String.duplicate("z", 30)),
       :invalid_provider_attempt_binding},
      {Map.put(expected_binding, "session_id", session_id <> "-other"), :superseded_owner}
    ]

    for {binding, expected_reason} <- tampered do
      fresh_worker =
        spawn(fn ->
          receive do
            message -> send(observer, {:fresh_permit_received, self(), message})
          after
            5_000 -> :ok
          end
        end)

      tampered_request =
        request
        |> replace_exact(worker, fresh_worker)
        |> replace_exact(permit_reference, make_ref())
        |> put_elem(1, binding)

      reply_alias = :erlang.alias([:reply])
      send(control, {:"$gen_call", {caller, [:alias | reply_alias]}, tampered_request})

      assert_receive {[:alias | ^reply_alias], {:error, ^expected_reason}}, 5_000
      refute_receive {:fresh_permit_received, ^fresh_worker, _message}, 0
      assert spent_attempt_bindings(control) == [expected_binding]
    end

    refute_receive {:trace, ^control, :send, _second_permit, ^worker}, 0

    send(worker, :release)
    assert await_event(attachment, "run.finished")["outcome"] == "completed"
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1
    :erlang.trace(control, false, [:all])
  end

  test "a crash after a page-size-one request row recovers its consecutive open without dispatching either page" do
    fixture =
      start(
        script: [
          %{text: "must not run", calls: []},
          %{text: "must still not run", calls: []}
        ],
        record_page_size_one: true
      )

    :ok =
      M1RuntimeTestStore.delay_after_record(
        fixture.store,
        "model_attempt_opened_v1",
        self()
      )

    run = Task.async(fn -> Fixture.run(fixture, "recover one row at a time") end)

    assert_receive {:record_linearized, waiter, _store, "model_attempt_opened_v1", _transition,
                    outcome},
                   5_000

    assert {:committed, _tx_id, receipt} = outcome
    assert receipt.journal_versions.last == receipt.journal_versions.first + 1
    assert AgentLoopTestModel.dispatched(fixture.model) == []
    assert {:ok, session_id} = only_session_id(fixture)

    retained_records = Fixture.records(fixture, session_id)
    retained_events = Fixture.events(fixture, session_id)

    request_prefix =
      Enum.filter(
        retained_records,
        &(&1.journal_version <= receipt.journal_versions.first)
      )

    event_prefix = events_before_receipt(retained_events, receipt)
    assert {:ok, request_only} = SessionState.recover(session_id, request_prefix, event_prefix)
    [pending_request] = SessionState.pending_work(request_only)
    assert pending_request.stage == "model_request_pending_attempt_open"
    refute Map.has_key?(pending_request, :request)
    refute Map.has_key?(pending_request, :attempt)
    refute Map.has_key?(pending_request, :stream_domain_id)

    request_run_id = Enum.find_value(request_prefix, & &1.payload["run_id"])
    {_declared, charged} = SessionState.accounting(request_only, request_run_id)
    assert charged == %{tokens: 0, source: nil}
    refute Enum.any?(SessionState.elements(request_only, request_run_id), &assistant_element?/1)
    refute Enum.any?(event_prefix, &(public_event_kind(&1) == "run.started"))

    coordinator = coordinator_of(fixture.runtime)
    Process.exit(coordinator, :kill)
    await_process_down(coordinator)
    M1RuntimeTestStore.release(waiter)
    _abandoned_origin = Task.yield(run, 50) || Task.shutdown(run, :brutal_kill)
    flush_record_pages()

    assert {:ok, ^session_id} =
             Loopex.resume_session(fixture.runtime, session_id,
               command_id: "resume-page-size-one-open"
             )

    {:ok, resumed} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)
    assert await_event(resumed, "run.finished")["outcome"] == "failed"
    assert AgentLoopTestModel.dispatched(fixture.model) == []

    recovery_pages = receive_record_pages()

    assert Enum.all?(recovery_pages, fn {_after_version, rows} -> length(rows) <= 1 end)

    assert consecutive_page_kinds(recovery_pages, "model_request_committed") == [
             "model_request_committed",
             "model_attempt_opened_v1"
           ]
  end

  test "a page-size-one settlement row applies no terminal semantics until its consecutive terminal row" do
    fixture =
      start(
        script: [
          %{text: "durable answer", calls: [], usage: %{input_tokens: 7, output_tokens: 5}}
        ],
        progress_to: self(),
        record_page_size_one: true
      )

    :ok =
      M1RuntimeTestStore.delay_after_record(
        fixture.store,
        "model_attempt_settled_v1",
        self()
      )

    {session_id, _attachment, {:accepted, "prompt-1"}} =
      Fixture.run(fixture, "settlement page boundary")

    assert_receive {:record_linearized, waiter, _store, "model_attempt_settled_v1", _transition,
                    {:committed, _tx_id, receipt}},
                   5_000

    assert receipt.journal_versions.last == receipt.journal_versions.first + 1
    retained_records = Fixture.records(fixture, session_id)
    retained_events = Fixture.events(fixture, session_id)

    settlement_prefix =
      Enum.filter(
        retained_records,
        &(&1.journal_version <= receipt.journal_versions.first)
      )

    event_prefix = events_before_receipt(retained_events, receipt)

    assert {:ok, settlement_only} =
             SessionState.recover(session_id, settlement_prefix, event_prefix)

    [pending_terminal] = SessionState.pending_work(settlement_only)
    assert pending_terminal.stage == "model_attempt_pending_terminal"

    settlement = List.last(settlement_prefix).payload
    run_id = settlement["run_id"]
    {_declared, charged} = SessionState.accounting(settlement_only, run_id)
    assert charged == %{tokens: 0, source: nil}
    refute Enum.any?(SessionState.elements(settlement_only, run_id), &assistant_element?/1)
    refute Enum.any?(event_prefix, &(public_event_kind(&1) == "run.finished"))
    refute Enum.any?(receive_progress(), &(&1.kind == :model_stream_closed))

    coordinator = coordinator_of(fixture.runtime)
    Process.exit(coordinator, :kill)
    await_process_down(coordinator)
    M1RuntimeTestStore.release(waiter)
    flush_record_pages()

    assert {:ok, ^session_id} =
             Loopex.resume_session(fixture.runtime, session_id,
               command_id: "resume-page-size-one-terminal"
             )

    {:ok, resumed} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)
    assert await_event(resumed, "run.finished")["outcome"] == "completed"
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1

    recovery_pages = receive_record_pages()
    assert Enum.all?(recovery_pages, fn {_after_version, rows} -> length(rows) <= 1 end)

    assert consecutive_page_kinds(recovery_pages, "model_attempt_settled_v1") == [
             "model_attempt_settled_v1",
             "run_terminal_committed"
           ]

    assert Enum.count(
             Fixture.events(fixture, session_id),
             &(public_event_kind(&1) == "run.finished")
           ) == 1
  end

  test "a blocked provider worker ignores wrong stale and duplicate permits and invokes once only for its exact fresh permit" do
    source =
      start(script: [%{text: "source", calls: [], hold: self(), hold_timeout_ms: 30_000}])

    source_attempt = queue_provider_permit_request(source, "source permit")
    resume_process(source_attempt.control)

    source_permit =
      await_control_permit(
        source_attempt.control,
        source_attempt.worker,
        source_attempt.binding
      )

    assert_receive {:holding, source_worker}, 5_000
    assert source_worker == source_attempt.worker

    target =
      start(script: [%{text: "target", calls: [], hold: self(), hold_timeout_ms: 30_000}])

    target_attempt = queue_provider_permit_request(target, "target permit")
    target_worker_pid = target_attempt.worker

    send(target_worker_pid, source_permit)
    refute_receive {:holding, ^target_worker_pid}, 50
    assert AgentLoopTestModel.dispatched(target.model) == []

    target_shaped_permit =
      source_permit
      |> retarget_permit(source_attempt, target_attempt)

    wrong_permit =
      replace_binding_field(
        target_shaped_permit,
        target_attempt.binding,
        "attempt",
        target_attempt.opened["attempt"] + 1
      )

    send(target_worker_pid, wrong_permit)
    refute_receive {:holding, ^target_worker_pid}, 50
    assert AgentLoopTestModel.dispatched(target.model) == []

    suspend_process(target_worker_pid)
    resume_process(target_attempt.control)

    target_permit =
      await_control_permit(
        target_attempt.control,
        target_attempt.worker,
        target_attempt.binding
      )

    send(target_worker_pid, target_permit)
    resume_process(target_worker_pid)
    assert_receive {:holding, target_worker}, 5_000
    assert target_worker == target_attempt.worker

    send(target_worker, :release)

    assert await_event(target_attempt.attachment, "run.finished")["outcome"] == "completed"
    assert length(AgentLoopTestModel.dispatched(target.model)) == 1

    send(source_worker, :release)
    assert await_event(source_attempt.attachment, "run.finished")["outcome"] == "completed"
    assert length(AgentLoopTestModel.dispatched(source.model)) == 1
  end

  test "same-owner worker death before a proved Control refusal retries once without charging the dead attempt" do
    fixture =
      start(
        script: [
          %{
            text: "only the retry may run",
            calls: [],
            usage: %{input_tokens: 3, output_tokens: 2}
          },
          %{text: "a third call must not run", calls: []}
        ]
      )

    attempt = queue_provider_permit_request(fixture, "same-owner worker down")
    worker_ref = Process.monitor(attempt.worker)
    Process.exit(attempt.worker, :kill)
    assert_receive {:DOWN, ^worker_ref, :process, _worker, :killed}, 5_000

    resume_process(attempt.control)
    assert await_event(attempt.attachment, "run.finished")["outcome"] == "completed"
    assert Process.alive?(attempt.coordinator)
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1

    records = Fixture.records(fixture, attempt.session_id)
    opens = records_of_kind(records, "model_attempt_opened_v1")
    settlements = records_of_kind(records, "model_attempt_settled_v1")

    assert Enum.map(opens, & &1["attempt"]) == [1, 2]
    assert Enum.map(settlements, & &1["attempt"]) == [1, 2]
    assert Enum.at(settlements, 0)["transport"] == "not_dispatched"
    assert Enum.at(settlements, 0)["next"] == "retry"

    assert Enum.at(settlements, 0)["accounting"] == %{
             "source" => "none",
             "basis" => "not_dispatched"
           }

    assert Enum.at(settlements, 1)["next"] == "terminal"
  end

  test "a third-party Model task DOWN after dispatch is ambiguous terminal evidence and never retries" do
    fixture = start(script: [], model_module: Loopex.ProviderAttemptExitModel)

    {session_id, attachment, {:accepted, "prompt-1"}} =
      Fixture.run(fixture, "third-party model task down")

    assert_receive {:provider_attempt_exit_model_called, worker, _request}, 5_000
    assert is_pid(worker)
    assert await_event(attachment, "run.finished")["outcome"] == "failed"
    refute_receive {:provider_attempt_exit_model_called, _other_worker, _request}, 100

    records = Fixture.records(fixture, session_id)
    assert Enum.map(records_of_kind(records, "model_attempt_opened_v1"), & &1["attempt"]) == [1]
    [settlement] = records_of_kind(records, "model_attempt_settled_v1")
    assert settlement["transport"] == "dispatched_or_unknown"
    assert settlement["termination"] == nil
    assert settlement["conversation"] == "none"
    assert settlement["next"] == "terminal"
    assert settlement["result"] == %{"kind" => "error", "category" => "model_call_failed"}

    assert settlement["accounting"] == %{
             "source" => "estimated",
             "basis" => "remaining_allowance"
           }
  end

  test "the authoritative origin closes its model stream before a terminal outcome can publish" do
    fixture =
      start(
        script: [
          %{text: "close before publish", calls: [], hold: self(), hold_timeout_ms: 30_000}
        ],
        progress_to: self()
      )

    {session_id, attachment, {:accepted, "prompt-1"}} =
      Fixture.run(fixture, "closure publication order")

    assert_receive {:holding, worker}, 5_000

    # ADR 0018 closes the origin's stream from durable settlement, before the
    # outcome publishes: while the settlement transaction is linearized but its
    # result is withheld from the coordinator, no closure may exist yet; once the
    # result reaches it, the closure precedes the terminal the reader observes.
    :ok = M1RuntimeTestStore.delay_after_record(fixture.store, "run_terminal_committed", self())

    send(worker, :release)

    assert_receive {:record_linearized, terminal_waiter, _store, "run_terminal_committed",
                    _transition, {:committed, _tx_id, _receipt}},
                   5_000

    refute_receive {:loopex_progress, %{kind: :model_stream_closed}}, 0

    M1RuntimeTestStore.release(terminal_waiter)

    assert_receive {:loopex_progress, %{kind: :model_stream_closed, disposition: :complete}},
                   5_000

    assert await_event(attachment, "run.finished")["outcome"] == "completed"
  end

  test "Control death or a lost reply before and after permit send never redispatches and only post-send cells invoke once" do
    for loss <- [:control_death, :lost_reply], phase <- [:before_send, :after_send] do
      result = exercise_control_loss(loss, phase)
      expected_calls = if phase == :after_send, do: 1, else: 0

      assert result.provider_calls == expected_calls,
             "#{loss} #{phase} invoked the provider #{result.provider_calls} times"

      assert Enum.map(result.opens, & &1["attempt"]) == [1]
      assert [settlement] = result.settlements
      assert settlement["transport"] == "dispatched_or_unknown"
      assert settlement["termination"] == "owner_loss"
      assert settlement["next"] == "terminal"

      assert settlement["accounting"] == %{
               "source" => "estimated",
               "basis" => "remaining_allowance"
             }

      refute Enum.any?(result.progress, fn item ->
               item.kind == :model_stream_closed and
                 item.stream_domain_id == result.predecessor_domain
             end)

      if phase == :after_send do
        assert Enum.any?(result.progress, fn item ->
                 item.kind == :text_delta and
                   item.stream_domain_id == result.predecessor_domain
               end)
      else
        refute Enum.any?(result.progress, fn item ->
                 item.stream_domain_id == result.predecessor_domain
               end)
      end
    end
  end

  test "a live owner handoff immediately before Control send invokes none while handoff immediately after send preserves only the predecessor call" do
    before_send = exercise_live_handoff(:before_send)
    after_send = exercise_live_handoff(:after_send)

    assert before_send.provider_calls == 0
    assert after_send.provider_calls == 1

    for result <- [before_send, after_send] do
      assert result.finished["outcome"] == "failed"
      assert Enum.map(result.opens, & &1["attempt"]) == [1]
      assert [settlement] = result.settlements
      assert settlement["transport"] == "dispatched_or_unknown"
      assert settlement["termination"] == "owner_loss"
      assert settlement["next"] == "terminal"

      assert settlement["accounting"] == %{
               "source" => "estimated",
               "basis" => "remaining_allowance"
             }
    end
  end

  test "a deadline proved before permit send settles uncharged with no call while a deadline after send settles that attempt conservatively without retry" do
    before_send = exercise_deadline_cell(:before_send)
    after_send = exercise_deadline_cell(:after_send)

    assert before_send.provider_calls == 0
    assert after_send.provider_calls == 1

    for result <- [before_send, after_send] do
      assert result.finished["outcome"] == "bound_reached"
      assert result.finished["bound"] == "deadline"
      assert Enum.map(result.opens, & &1["attempt"]) == [1]
      assert [settlement] = result.settlements
      assert settlement["termination"] == "deadline"
      assert settlement["next"] == "terminal"
    end

    [before_settlement] = before_send.settlements
    assert before_settlement["transport"] == "not_dispatched"

    assert before_settlement["accounting"] == %{
             "source" => "none",
             "basis" => "not_dispatched"
           }

    [after_settlement] = after_send.settlements
    assert after_settlement["transport"] == "dispatched_or_unknown"

    assert after_settlement["accounting"] == %{
             "source" => "estimated",
             "basis" => "remaining_allowance"
           }
  end

  test "only exact pre-canary not_dispatched proof opens one retry whose accounting and stream domain stay bound to its attempt" do
    retry =
      start(
        script: [
          %{raw_result: {:error, {:not_dispatched, "model_call_failed"}}},
          %{
            text: "done",
            calls: [],
            deltas: ["retry"],
            usage: %{input_tokens: 7, output_tokens: 5}
          },
          %{
            text: "successor",
            calls: [],
            deltas: ["successor"],
            usage: %{input_tokens: 11, output_tokens: 13}
          }
        ],
        progress_to: self()
      )

    {session_id, attachment, {:accepted, "prompt-1"}} = Fixture.run(retry, "retry exactly once")
    assert await_event(attachment, "run.finished")["outcome"] == "completed"
    assert length(AgentLoopTestModel.dispatched(retry.model)) == 2

    assert {:accepted, "successor-run"} =
             Loopex.command(attachment, %{
               type: :prompt,
               command_id: "successor-run",
               content: "start a new operation"
             })

    assert await_event(attachment, "run.finished")["outcome"] == "completed"
    assert length(AgentLoopTestModel.dispatched(retry.model)) == 3

    records = Fixture.records(retry, session_id)
    opens = records_of_kind(records, "model_attempt_opened_v1")
    settlements = records_of_kind(records, "model_attempt_settled_v1")

    assert Enum.map(opens, & &1["attempt"]) == [1, 2, 1]

    assert Enum.map(settlements, & &1["transport"]) == [
             "not_dispatched",
             "dispatched_or_unknown",
             "dispatched_or_unknown"
           ]

    assert Enum.map(settlements, & &1["next"]) == ["retry", "terminal", "terminal"]
    assert Enum.at(opens, 0)["run_id"] == Enum.at(opens, 1)["run_id"]
    refute Enum.at(opens, 1)["run_id"] == Enum.at(opens, 2)["run_id"]

    assert Enum.map(settlements, & &1["accounting"]) == [
             %{"source" => "none", "basis" => "not_dispatched"},
             %{"source" => "reported", "input_tokens" => 7, "output_tokens" => 5},
             %{"source" => "reported", "input_tokens" => 11, "output_tokens" => 13}
           ]

    attempt_identities =
      Enum.map(settlements, fn settlement ->
        Map.take(settlement, ["run_id", "turn_id", "operation_id", "attempt"])
      end)

    assert length(Enum.uniq(attempt_identities)) == 3

    for {label, mutated} <- invalid_attempt_histories(records) do
      assert {:error, _invalid_attempt_position} =
               SessionState.recover(session_id, mutated, Fixture.events(retry, session_id)),
             "#{label} provider-attempt history was admitted"
    end

    progress = receive_progress()
    domains = progress |> Enum.map(& &1.stream_domain_id) |> Enum.uniq()

    expected_domains =
      Enum.map(opens, fn opened ->
        StreamDomain.derive(
          :model,
          session_id,
          opened["operation_id"],
          opened["attempt"]
        )
      end)

    assert MapSet.new(domains) == MapSet.new(expected_domains)
    assert Enum.count(progress, &(&1.kind == :model_stream_closed)) == 3

    for domain <- expected_domains do
      assert Enum.count(progress, &(&1.stream_domain_id == domain)) >= 1

      assert Enum.count(
               progress,
               &(&1.stream_domain_id == domain and &1.kind == :model_stream_closed)
             ) == 1
    end

    assert {:ok, recovered} =
             SessionState.recover(session_id, records, Fixture.events(retry, session_id))

    first_run_id = Enum.at(opens, 0)["run_id"]
    successor_run_id = Enum.at(opens, 2)["run_id"]
    {_first_declared, first_charged} = SessionState.accounting(recovered, first_run_id)

    {_successor_declared, successor_charged} =
      SessionState.accounting(recovered, successor_run_id)

    assert {first_charged.tokens, first_charged.source} == {12, :reported}
    assert {successor_charged.tokens, successor_charged.source} == {24, :reported}

    for raw_result <- [
          {:error, {:dispatched_or_unknown, "model_call_failed"}},
          {:error, :timeout},
          {:error, {:not_dispatched, "credential-shaped-raw-error"}},
          {:error, {:not_dispatched, :model_call_failed}},
          {:not_dispatched, "model_call_failed"},
          {:ok, :malformed_reply}
        ] do
      no_retry = start(script: [%{raw_result: raw_result}, %{text: "must not run", calls: []}])

      {no_retry_session, no_retry_attachment, {:accepted, "prompt-1"}} =
        Fixture.run(no_retry, "do not retry")

      finished = await_event(no_retry_attachment, "run.finished")
      assert finished["outcome"] == "failed"
      assert length(AgentLoopTestModel.dispatched(no_retry.model)) == 1

      no_retry_records = Fixture.records(no_retry, no_retry_session)

      assert Enum.map(
               records_of_kind(no_retry_records, "model_attempt_opened_v1"),
               & &1["attempt"]
             ) == [1]

      [no_retry_settlement] = records_of_kind(no_retry_records, "model_attempt_settled_v1")
      assert no_retry_settlement["transport"] == "dispatched_or_unknown"

      assert no_retry_settlement["accounting"] == %{
               "source" => "estimated",
               "basis" => "remaining_allowance"
             }

      refute inspect(no_retry_records) =~ "credential-shaped-raw-error"
    end
  end

  test "two exact not-dispatched settlements consume the version-one allowance with no third attempt" do
    fixture =
      start(
        script: [
          %{raw_result: {:error, {:not_dispatched, "model_call_failed"}}},
          %{raw_result: {:error, {:not_dispatched, "model_call_failed"}}},
          %{text: "attempt three must not run", calls: []}
        ]
      )

    {session_id, attachment, {:accepted, "prompt-1"}} =
      Fixture.run(fixture, "refuse exactly twice")

    assert await_event(attachment, "run.finished")["outcome"] == "failed"
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 2

    records = Fixture.records(fixture, session_id)
    opens = records_of_kind(records, "model_attempt_opened_v1")
    settlements = records_of_kind(records, "model_attempt_settled_v1")

    assert Enum.map(opens, & &1["attempt"]) == [1, 2]
    assert Enum.map(settlements, & &1["attempt"]) == [1, 2]
    assert Enum.map(settlements, & &1["transport"]) == ["not_dispatched", "not_dispatched"]
    assert Enum.map(settlements, & &1["next"]) == ["retry", "terminal"]
    assert Enum.map(settlements, & &1["conversation"]) == ["none", "none"]

    assert Enum.map(settlements, & &1["accounting"]) == [
             %{"source" => "none", "basis" => "not_dispatched"},
             %{"source" => "none", "basis" => "not_dispatched"}
           ]

    for opened <- opens do
      assert_exact_keys(opened, [
        "kind",
        "run_id",
        "turn_id",
        "operation_id",
        "attempt",
        "staged_request_digest"
      ])
    end

    for settlement <- settlements do
      assert_exact_settlement_schema(settlement)
    end

    second_settlement_index =
      record_index(records, "model_attempt_settled_v1", &(&1["attempt"] == 2))

    terminal_index = record_index(records, "run_terminal_committed", fn _ -> true end)
    assert terminal_index == second_settlement_index + 1

    assert {:ok, _recovered} =
             SessionState.recover(session_id, records, Fixture.events(fixture, session_id))

    for {label, invalid_records} <- [
          {"attempt-open extra key", add_payload_key(records, "model_attempt_opened_v1")},
          {"settlement extra key", add_payload_key(records, "model_attempt_settled_v1")}
        ] do
      assert {:error, _invalid_exact_schema} =
               SessionState.recover(
                 session_id,
                 invalid_records,
                 Fixture.events(fixture, session_id)
               ),
             "#{label} survived replay"
    end
  end

  # Concept: the two settlement combinations the record is allowed to refuse and
  # the reducer is not allowed to have to survive.
  #
  # Technical depth: ADR 0018 closes its valid-combination table with "all other
  # combinations are invalid history, including ... attempt-two retry", and
  # combination 2 fixes a late valid reply as evidence-only. Both are properties
  # of the twelve-key record alone, so replay is where they hold: a settlement
  # that reached the journal is read back by every later owner, and a
  # combination the validator admits becomes a state the reducer must then act
  # on. Each case mutates exactly the one member the clause names and leaves the
  # rest of a real history untouched, so a refusal here names that cell rather
  # than an unrelated history shape.
  # Concept: a deadline that could not be written down decides nothing.
  #
  # Technical depth: the settlement reads which termination won from applied
  # state, so a `model_termination_admitted_v1` the Store refused leaves the
  # attempt looking unterminated -- and the reply the provider then returns is
  # taken as the canonical answer of a run that had actually reached its bound.
  # ADR 0018 makes an unexpected refusal of a bounded record the session's
  # unavailability and forbids inventing the settlement, accounting,
  # conversation, or terminal that would have followed it. The owner therefore
  # ends, and the journal holds no verdict at all rather than the wrong one.
  test "a deadline admission the Store refuses ends the owner and fabricates no verdict" do
    fixture =
      start(
        script: [
          %{
            text: "late reply",
            calls: [],
            usage: %{input_tokens: 7, output_tokens: 5},
            hold: self(),
            hold_timeout_ms: 30_000
          }
        ],
        bounds_token_budget: 100,
        bounds_deadline_ms: 200
      )

    :ok = M1RuntimeTestStore.refuse_next_record(fixture.store, "model_termination_admitted_v1")

    {session_id, _attachment, {:accepted, "prompt-1"}} =
      Fixture.run(fixture, "deadline refused")

    assert_receive {:holding, worker}, 5_000

    owner = coordinator_of(fixture.runtime)
    reference = Process.monitor(owner)

    assert_receive {:DOWN, ^reference, :process, ^owner,
                    {:model_termination_failed, :refused_by_test_store}},
                   15_000,
                   "the refused deadline admission did not end the owner that could not admit it"

    send(worker, :release)

    records = Fixture.records(fixture, session_id)
    assert records_of_kind(records, "model_termination_admitted_v1") == []
    assert records_of_kind(records, "model_attempt_settled_v1") == []
    assert records_of_kind(records, "run_terminal_committed") == []
  end

  # Concept: how long Control remembers that an attempt identity was spent.
  #
  # Technical depth: ADR 0018 requires the spend to outlive the coordinator and
  # the worker for the complete ownership generation -- "replacing the
  # coordinator or worker does not clear it" -- because a successor that could
  # re-spend an identity could make a second provider call on an attempt that
  # may already have been billed. So a succession is exactly the moment the map
  # must not be pruned, and this states that. What it may not do is outlive the
  # session's ownership itself, which is why the entry is dropped on the one
  # line that removes the session from Control. The retained key is the exact
  # attempt binding, which is also the value the refusal is compared against.
  test "a spent attempt identity is the exact attempt binding and outlives the owner that spent it" do
    fixture = start(script: [%{text: "one attempt", calls: []}])

    {session_id, attachment, {:accepted, "prompt-1"}} = Fixture.run(fixture, "spend one identity")
    assert await_event(attachment, "run.finished")["outcome"] == "completed"

    {:ok, %{control: control}} = Runtime.children(fixture.runtime)

    [opened] =
      fixture |> Fixture.records(session_id) |> records_of_kind("model_attempt_opened_v1")

    binding = Map.put(attempt_identity(opened), "session_id", session_id)

    assert spent_attempt_bindings(control) == [binding]

    assert {:ok, ^session_id} =
             Loopex.resume_session(fixture.runtime, session_id, command_id: "resume-once")

    assert spent_attempt_bindings(control) == [binding]
  end

  # Concept: an abort that lands after the attempt opened and before anything
  # asked Control for the permit ends an attempt that cost nothing.
  #
  # Technical depth: ADR 0018 puts provider dispatch at Control's permit send, so
  # this window is a cell of its table rather than a gap in it: this owner holds
  # the open attempt, it has not called `Control.provider_dispatch/3`, and no
  # other process may spend that identity. Combination 4 leaves such an attempt
  # uncharged. Charging it `estimated` remaining allowance -- what an unqualified
  # `dispatched_or_unknown` does -- bills the run's whole remaining token budget
  # for a call that provably never happened, and does it on the ordinary abort
  # path rather than in some rare recovery.
  #
  # The window is entered by holding the attempt-open transaction in the Store:
  # the abort reaches the coordinator's mailbox while it is blocked in that
  # commit, and the `:advance_work` the commit sends itself is appended behind
  # it. That is the real ordering, not a simulated one.
  test "an abort between the attempt open and the Control permit settles uncharged with no call" do
    fixture = start(script: [%{text: "never dispatched", calls: []}])

    :ok =
      M1RuntimeTestStore.hold_next_record_before_linearization(
        fixture.store,
        "model_attempt_opened_v1",
        self()
      )

    {session_id, attachment, {:accepted, "prompt-1"}} =
      Fixture.run(fixture, "abort before the permit")

    assert_receive {:record_held_before_linearization, waiter, _store, "model_attempt_opened_v1",
                    _transaction},
                   5_000

    coordinator = coordinator_of(fixture.runtime)

    aborting =
      Task.async(fn ->
        Loopex.command(attachment, %{type: :abort, command_id: "abort-before-permit"})
      end)

    assert await_queued_command(coordinator)
    M1RuntimeTestStore.release(waiter)

    assert Task.await(aborting, 15_000) == {:accepted, "abort-before-permit"}
    assert await_event(attachment, "run.finished")["outcome"] == "cancelled"
    assert AgentLoopTestModel.dispatched(fixture.model) == []

    records = Fixture.records(fixture, session_id)
    assert [opened] = records_of_kind(records, "model_attempt_opened_v1")
    assert opened["attempt"] == 1
    assert [settlement] = records_of_kind(records, "model_attempt_settled_v1")

    assert settlement["transport"] == "not_dispatched"
    assert settlement["accounting"] == %{"source" => "none", "basis" => "not_dispatched"}
    assert settlement["termination"] == "abort"
    assert settlement["conversation"] == "none"
    assert settlement["next"] == "terminal"

    assert {:ok, recovered} =
             SessionState.recover(session_id, records, Fixture.events(fixture, session_id))

    {_declared, charged} = SessionState.accounting(recovered, settlement["run_id"])
    assert charged.tokens == 0
    assert charged.source == nil
  end

  test "an attempt-two retry settlement is refused at replay rather than opening a third attempt" do
    fixture =
      start(
        script: [
          %{raw_result: {:error, {:not_dispatched, "model_call_failed"}}},
          %{raw_result: {:error, {:not_dispatched, "model_call_failed"}}}
        ]
      )

    {session_id, attachment, {:accepted, "prompt-1"}} =
      Fixture.run(fixture, "refuse exactly twice")

    assert await_event(attachment, "run.finished")["outcome"] == "failed"

    records = Fixture.records(fixture, session_id)
    events = Fixture.events(fixture, session_id)

    assert {:ok, _recovered} = SessionState.recover(session_id, records, events)

    exhausted_retry = retry_at_the_attempt_limit(records)
    open_run = Enum.reject(events, &(public_event_kind(&1) == "run.finished"))

    assert SessionState.recover(session_id, exhausted_retry, open_run) ==
             {:error, :invalid_attempt_settlement}
  end

  test "a terminated reply outside the evidence-only conversation is refused at replay" do
    fixture =
      start(
        script: [
          %{
            text: "late reply",
            calls: [],
            usage: %{input_tokens: 7, output_tokens: 5},
            hold: self(),
            hold_timeout_ms: 30_000
          }
        ],
        bounds_token_budget: 100
      )

    {session_id, attachment, {:accepted, "prompt-1"}} = Fixture.run(fixture, "abort first")
    assert_receive {:holding, worker}, 5_000

    assert {:accepted, "abort-first"} =
             Loopex.command(attachment, %{type: :abort, command_id: "abort-first"})

    assert await_record(fixture, session_id, fn record ->
             record_kind(record.payload) == "command_admitted" and
               record.payload["command_type"] == "abort" and
               record.payload["admission"] == "accepted"
           end)

    send(worker, :release)
    assert await_event(attachment, "run.finished")["outcome"] == "cancelled"

    records = Fixture.records(fixture, session_id)
    events = Fixture.events(fixture, session_id)

    [settlement] = records_of_kind(records, "model_attempt_settled_v1")
    assert settlement["termination"] == "abort"
    assert settlement["conversation"] == "evidence_only"
    assert settlement["result"]["kind"] == "reply"

    assert {:ok, _recovered} = SessionState.recover(session_id, records, events)

    silent_late_reply =
      rewrite_settlement(records, &(&1["attempt"] == 1), fn payload ->
        Map.put(payload, "conversation", "none")
      end)

    assert {:error, _invalid_attempt_settlement} =
             SessionState.recover(session_id, silent_late_reply, events)
  end

  test "succession preserves retry permission but never resets or reopens the two-attempt allowance" do
    between = exercise_retry_succession(:between_attempts)
    assert between.finished["outcome"] == "completed"
    assert between.provider_calls == 2
    assert Enum.map(between.opens, & &1["attempt"]) == [1, 2]

    assert Enum.map(between.settlements, &{&1["attempt"], &1["next"]}) == [
             {1, "retry"},
             {2, "terminal"}
           ]

    after_open = exercise_retry_succession(:after_attempt_two_open)
    assert after_open.finished["outcome"] == "failed"
    assert after_open.provider_calls == 1
    assert Enum.map(after_open.opens, & &1["attempt"]) == [1, 2]
    assert Enum.map(after_open.settlements, & &1["attempt"]) == [1, 2]
    assert List.last(after_open.settlements)["termination"] == "owner_loss"
    assert List.last(after_open.settlements)["next"] == "terminal"
  end

  test "reply preflight admits one below and at each Store byte depth and cardinality limit and compacts one above" do
    for target <- [@record_limit - 1, @record_limit, @record_limit + 1] do
      text = text_for_settlement_bytes(target)
      reply = canonical_reply(text: text)
      candidate = settlement_candidate(reply)
      assert record_bytes(candidate) == target

      settlement = run_reply_preflight(text: text)

      if target <= @record_limit do
        assert :ok = Store.validate_private_record(candidate)
        assert settlement["result"]["kind"] == "reply"
        assert settlement["result"]["reply"]["text"] == text
        assert record_bytes(settlement) == target
      else
        assert {:error, _over_limit} = Store.validate_private_record(candidate)

        assert settlement["result"] == %{
                 "kind" => "error",
                 "category" => "unreadable_model_answer"
               }

        assert settlement["accounting"] == %{
                 "source" => "reported",
                 "input_tokens" => 3,
                 "output_tokens" => 2
               }
      end
    end

    assert_structural_preflight_boundary(:depth)
    assert_structural_preflight_boundary(:cardinality)
  end

  test "a callback aggregate over the Store byte limit completes when its request and durable reply projections each fit" do
    request_text = String.duplicate("q", 15_000)
    reply_text = String.duplicate("a", 55_000)

    fixture =
      start(
        script: [
          %{text: reply_text, calls: [], usage: %{input_tokens: 7, output_tokens: 5}}
        ],
        bounds_token_budget: 100_000
      )

    {session_id, attachment, {:accepted, "prompt-1"}} = Fixture.run(fixture, request_text)
    assert await_event(attachment, "run.finished")["outcome"] == "completed"

    [request_record] =
      fixture |> Fixture.records(session_id) |> records_of_kind("model_request_committed")

    [settlement] =
      fixture |> Fixture.records(session_id) |> records_of_kind("model_attempt_settled_v1")

    [dispatched_request] = AgentLoopTestModel.dispatched(fixture.model)
    durable_reply = settlement["result"]["reply"]

    callback_reply =
      Map.put(
        durable_reply,
        "canonical_request_bytes",
        dispatched_request.canonical_request_bytes
      )

    request_bytes = record_bytes(request_record)
    settlement_bytes = record_bytes(settlement)
    assert request_bytes <= @record_limit
    assert settlement_bytes <= @record_limit

    assert byte_size(:erlang.term_to_binary(callback_reply, [:deterministic])) > @record_limit
    assert settlement["result"]["kind"] == "reply"
    assert settlement["result"]["reply"]["text"] == reply_text
    assert_exact_settlement_schema(settlement)
  end

  test "a credential-shaped raw provider error becomes one generic terminal and enters no retained runtime plane" do
    secret = "provider-credential-shaped-value-never-retained-or-rendered"

    fixture =
      start(
        script: [
          %{raw_result: {:error, {:provider_credential, secret}}},
          %{text: "a retry would be a leak of authority", calls: []}
        ],
        progress_to: self(),
        diagnostics_to: self(),
        bounds_token_budget: 113
      )

    {session_id, attachment, {:accepted, "prompt-1"}} =
      Fixture.run(fixture, "keep provider errors private")

    public_events = await_events_through(attachment, "run.finished")
    finished = Enum.find(public_events, &(&1.kind == "run.finished"))
    assert finished["outcome"] == "failed"
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1

    records = Fixture.records(fixture, session_id)
    [settlement] = records_of_kind(records, "model_attempt_settled_v1")

    assert settlement["result"] == %{
             "kind" => "error",
             "category" => "model_call_failed"
           }

    assert settlement["transport"] == "dispatched_or_unknown"
    assert settlement["next"] == "terminal"

    {:ok, session_status} = Loopex.session_status(fixture.runtime, session_id)
    attachment_status = Loopex.attachment_status(attachment)
    snapshot = Loopex.snapshot(attachment)
    progress = receive_progress()
    diagnostics = receive_diagnostics()
    durable_store = M1RuntimeTestStore.inspect_state(fixture.store)
    model_fixture = :sys.get_state(fixture.model)
    durable_public = Fixture.events(fixture, session_id)

    planes = [
      durable: records,
      durable_store: durable_store,
      durable_public: durable_public,
      public: public_events,
      progress: progress,
      diagnostic: diagnostics,
      status: [session_status, attachment_status, snapshot],
      terminal: finished,
      fixture: model_fixture
    ]

    for {plane, value} <- planes do
      refute printable(value) =~ secret, "credential-shaped error entered the #{plane} plane"
    end

    refute printable(planes) =~ secret

    durable_bytes =
      :erlang.term_to_binary([records, durable_store, durable_public], [:deterministic])

    assert :binary.match(durable_bytes, secret) == :nomatch
  end

  test "request-open commit-unknown re-presents identical bytes and dispatches only after the retained pair resolves" do
    fixture =
      start(
        script: [%{text: "committed once", calls: [], hold: self()}],
        progress_to: self()
      )

    :ok =
      M1RuntimeTestStore.hold_next_record_before_linearization(
        fixture.store,
        "model_attempt_opened_v1",
        self()
      )

    {session_id, attachment, {:accepted, "prompt-1"}} =
      Fixture.run(fixture, "retain request and open")

    assert_receive {:record_held_before_linearization, first_waiter, _store,
                    "model_attempt_opened_v1", first_transaction},
                   5_000

    assert Enum.map(first_transaction.records, &record_kind/1) == [
             "model_request_committed",
             "model_attempt_opened_v1"
           ]

    replay_waiter =
      hold_commit_unknown_replay(
        fixture.store,
        "model_attempt_opened_v1",
        first_waiter,
        first_transaction
      )

    assert AgentLoopTestModel.dispatched(fixture.model) == []
    refute_receive {:holding, _provider_worker}, 0

    refute Enum.any?(available_events(attachment), &(&1.kind == "run.started"))
    refute Enum.any?(receive_progress(), &(&1.kind == :model_stream_closed))

    M1RuntimeTestStore.release(replay_waiter)
    assert_receive {:holding, provider_worker}, 5_000
    send(provider_worker, :release)
    assert await_event(attachment, "run.finished")["outcome"] == "completed"
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1

    records = Fixture.records(fixture, session_id)
    assert length(records_of_kind(records, "model_request_committed")) == 1
    assert length(records_of_kind(records, "model_attempt_opened_v1")) == 1
  end

  test "retry-open commit-unknown re-presents identical bytes and dispatches attempt two only after the retained open resolves" do
    fixture =
      start(
        script: [
          %{raw_result: {:error, {:not_dispatched, "model_call_failed"}}},
          %{text: "retry once", calls: [], hold: self()}
        ],
        progress_to: self()
      )

    :ok =
      M1RuntimeTestStore.delay_after_record(
        fixture.store,
        "model_attempt_settled_v1",
        self()
      )

    {session_id, attachment, {:accepted, "prompt-1"}} =
      Fixture.run(fixture, "retain retry open")

    assert_receive {:record_linearized, settlement_waiter, _store, "model_attempt_settled_v1",
                    _transition, {:committed, _settlement_tx_id, _settlement_receipt}},
                   5_000

    :ok =
      M1RuntimeTestStore.hold_next_record_before_linearization(
        fixture.store,
        "model_attempt_opened_v1",
        self()
      )

    M1RuntimeTestStore.release(settlement_waiter)

    assert_receive {:record_held_before_linearization, first_waiter, _store,
                    "model_attempt_opened_v1", first_transaction},
                   5_000

    assert [opened] = first_transaction.records
    assert record_kind(opened) == "model_attempt_opened_v1"
    assert opened["attempt"] == 2

    replay_waiter =
      hold_commit_unknown_replay(
        fixture.store,
        "model_attempt_opened_v1",
        first_waiter,
        first_transaction
      )

    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1
    refute_receive {:holding, _retry_worker}, 0

    # Attempt one's not-dispatched domain closes at its own settlement, which is
    # already durable; the retry's domain opens no item and publishes no closure
    # while its open row is held.
    closures = Enum.filter(receive_progress(), &(&1.kind == :model_stream_closed))
    assert length(closures) <= 1
    refute Enum.any?(closures, &(&1.disposition == :complete))

    M1RuntimeTestStore.release(replay_waiter)
    assert_receive {:holding, retry_worker}, 5_000
    send(retry_worker, :release)
    assert await_event(attachment, "run.finished")["outcome"] == "completed"
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 2

    records = Fixture.records(fixture, session_id)

    assert Enum.map(records_of_kind(records, "model_attempt_opened_v1"), & &1["attempt"]) == [
             1,
             2
           ]
  end

  test "continue-settlement commit-unknown re-presents identical accounting and conversation bytes before tool or next-turn dispatch" do
    first_call = %{
      "id" => "commit-unknown-tool",
      "name" => "write",
      "arguments" => %{"path" => "result.txt"}
    }

    fixture =
      start(
        script: [
          %{
            text: "use the tool",
            calls: [first_call],
            usage: %{input_tokens: 7, output_tokens: 5}
          },
          %{text: "finished", calls: [], hold: self()}
        ],
        tools: [Fixture.tool_definition()],
        progress_to: self()
      )

    :ok =
      M1RuntimeTestStore.hold_next_record_before_linearization(
        fixture.store,
        "model_attempt_settled_v1",
        self()
      )

    {session_id, attachment, {:accepted, "prompt-1"}} =
      Fixture.run(fixture, "retain continue settlement")

    assert_receive {:record_held_before_linearization, first_waiter, _store,
                    "model_attempt_settled_v1", first_transaction},
                   5_000

    assert [settlement] = first_transaction.records
    assert record_kind(settlement) == "model_attempt_settled_v1"
    assert settlement["conversation"] == "canonical"
    assert settlement["next"] == "continue"

    assert settlement["accounting"] == %{
             "source" => "reported",
             "input_tokens" => 7,
             "output_tokens" => 5
           }

    replay_waiter =
      hold_commit_unknown_replay(
        fixture.store,
        "model_attempt_settled_v1",
        first_waiter,
        first_transaction
      )

    assert Loopex.AgentLoopTestExecutor.jobs(fixture.executor) == []
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1
    refute_receive {:holding, _next_turn_worker}, 0
    refute Enum.any?(receive_progress(), &(&1.kind == :model_stream_closed))

    M1RuntimeTestStore.release(replay_waiter)
    assert_receive {:holding, next_turn_worker}, 5_000
    assert length(Loopex.AgentLoopTestExecutor.jobs(fixture.executor)) == 1
    send(next_turn_worker, :release)
    assert await_event(attachment, "run.finished")["outcome"] == "completed"
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 2

    settlements =
      fixture
      |> Fixture.records(session_id)
      |> records_of_kind("model_attempt_settled_v1")

    assert Enum.count(settlements, &(&1 == settlement)) == 1
  end

  test "terminal-settlement commit-unknown re-presents identical accounting conversation and terminal bytes before closure or publication" do
    fixture =
      start(
        script: [
          %{
            text: "finish once",
            calls: [],
            usage: %{input_tokens: 11, output_tokens: 13}
          }
        ],
        progress_to: self()
      )

    :ok =
      M1RuntimeTestStore.hold_next_record_before_linearization(
        fixture.store,
        "model_attempt_settled_v1",
        self()
      )

    {session_id, attachment, {:accepted, "prompt-1"}} =
      Fixture.run(fixture, "retain terminal settlement")

    assert_receive {:record_held_before_linearization, first_waiter, _store,
                    "model_attempt_settled_v1", first_transaction},
                   5_000

    assert [settlement, terminal] = first_transaction.records

    assert Enum.map(first_transaction.records, &record_kind/1) == [
             "model_attempt_settled_v1",
             "run_terminal_committed"
           ]

    assert settlement["conversation"] == "canonical"
    assert settlement["next"] == "terminal"

    assert settlement["accounting"] == %{
             "source" => "reported",
             "input_tokens" => 11,
             "output_tokens" => 13
           }

    assert terminal["run_id"] == settlement["run_id"]

    replay_waiter =
      hold_commit_unknown_replay(
        fixture.store,
        "model_attempt_settled_v1",
        first_waiter,
        first_transaction
      )

    refute Enum.any?(available_events(attachment), &(&1.kind == "run.finished"))
    refute Enum.any?(receive_progress(), &(&1.kind == :model_stream_closed))

    M1RuntimeTestStore.release(replay_waiter)
    assert await_event(attachment, "run.finished")["outcome"] == "completed"

    records = Fixture.records(fixture, session_id)

    assert Enum.count(records_of_kind(records, "model_attempt_settled_v1"), &(&1 == settlement)) ==
             1

    assert Enum.count(records_of_kind(records, "run_terminal_committed"), &(&1 == terminal)) == 1

    assert Enum.count(receive_progress(), &(&1.kind == :model_stream_closed)) == 1
  end

  test "provider settlement atomically preserves accounting and first durable termination precedence without false effect or bound outcomes" do
    request_text = String.duplicate("q", 15_000)
    reply_text = String.duplicate("a", 55_000)

    exact =
      start(
        script: [
          %{text: reply_text, calls: [], usage: %{input_tokens: 7, output_tokens: 5}}
        ],
        bounds_token_budget: 100_000
      )

    :ok =
      M1RuntimeTestStore.hold_next_record_before_linearization(
        exact.store,
        "model_attempt_settled_v1",
        self()
      )

    {exact_session, exact_attachment, {:accepted, "prompt-1"}} =
      Fixture.run(exact, request_text)

    assert_receive {:record_held_before_linearization, exact_waiter, _store,
                    "model_attempt_settled_v1", exact_transaction},
                   5_000

    assert Enum.map(exact_transaction.records, &record_kind/1) == [
             "model_attempt_settled_v1",
             "run_terminal_committed"
           ]

    result_first_abort =
      Task.async(fn ->
        Loopex.command(exact_attachment, %{type: :abort, command_id: "abort-after-result"})
      end)

    M1RuntimeTestStore.release(exact_waiter)

    assert await_event(exact_attachment, "run.finished")["outcome"] == "completed"
    assert {:error, :no_active_run} = Task.await(result_first_abort, 5_000)
    exact_records = Fixture.records(exact, exact_session)
    [request] = records_of_kind(exact_records, "model_request_committed")
    [settlement] = records_of_kind(exact_records, "model_attempt_settled_v1")

    assert settlement["accounting"] == %{
             "source" => "reported",
             "input_tokens" => 7,
             "output_tokens" => 5
           }

    assert settlement["result"]["kind"] == "reply"
    assert settlement["result"]["reply"]["text"] == reply_text
    assert {:ok, _request, request_bytes} = normalize(request)
    assert {:ok, _settlement, settlement_bytes} = normalize(settlement)
    assert request_bytes <= @record_limit
    assert settlement_bytes <= @record_limit
    assert request_bytes + settlement_bytes > @record_limit

    unreadable =
      start(
        script: [
          %{
            text: String.duplicate("x", @record_limit + 1),
            calls: [],
            usage: %{input_tokens: 3, output_tokens: 2}
          }
        ],
        bounds_token_budget: 100
      )

    {unreadable_session, unreadable_attachment, {:accepted, "prompt-1"}} =
      Fixture.run(unreadable, "oversized answer")

    unreadable_finished = await_event(unreadable_attachment, "run.finished")

    [unreadable_settlement] =
      unreadable
      |> Fixture.records(unreadable_session)
      |> records_of_kind("model_attempt_settled_v1")

    assert unreadable_settlement["result"] == %{
             "kind" => "error",
             "category" => "unreadable_model_answer"
           }

    assert unreadable_settlement["accounting"] == %{
             "source" => "reported",
             "input_tokens" => 3,
             "output_tokens" => 2
           }

    assert unreadable_finished["outcome"] == "failed"
    assert length(AgentLoopTestModel.dispatched(unreadable.model)) == 1
    assert_exact_settlement_schema(unreadable_settlement)

    malformed =
      start(
        script: [
          %{
            text: "not retained",
            calls: [],
            usage: %{input_tokens: 4, output_tokens: 3},
            reply_overrides: %{
              identity: %{provider: nil, model: "scripted:v1", endpoint: "in-process"}
            }
          }
        ],
        bounds_token_budget: 100
      )

    {malformed_session, malformed_attachment, {:accepted, "prompt-1"}} =
      Fixture.run(malformed, "malformed answer")

    assert await_event(malformed_attachment, "run.finished")["outcome"] == "failed"

    [malformed_settlement] =
      malformed
      |> Fixture.records(malformed_session)
      |> records_of_kind("model_attempt_settled_v1")

    assert malformed_settlement["result"] == %{
             "kind" => "error",
             "category" => "unreadable_model_answer"
           }

    assert malformed_settlement["accounting"] == %{
             "source" => "reported",
             "input_tokens" => 4,
             "output_tokens" => 3
           }

    assert length(AgentLoopTestModel.dispatched(malformed.model)) == 1
    assert_exact_settlement_schema(malformed_settlement)

    for reply_overrides <- [
          %{unexpected_reply_key: true},
          %{
            identity: %{
              provider: "scripted",
              model: "scripted:v1",
              endpoint: "in-process",
              unexpected_identity_key: true
            }
          },
          %{usage: %{input_tokens: 3, output_tokens: 2, unexpected_usage_key: true}},
          %{
            tool_calls: [
              %{
                "id" => "extra-key-call",
                "name" => "write",
                "arguments" => %{"path" => "x"},
                "unexpected_tool_call_key" => true
              }
            ]
          }
        ] do
      extra_key =
        start(
          script: [
            %{
              text: "must compact",
              calls: [],
              usage: %{input_tokens: 3, output_tokens: 2},
              reply_overrides: reply_overrides
            }
          ],
          tools: [Fixture.tool_definition()]
        )

      {extra_session, extra_attachment, {:accepted, "prompt-1"}} =
        Fixture.run(extra_key, "reject callback extra key")

      assert await_event(extra_attachment, "run.finished")["outcome"] == "failed"

      [extra_settlement] =
        extra_key
        |> Fixture.records(extra_session)
        |> records_of_kind("model_attempt_settled_v1")

      assert extra_settlement["result"] == %{
               "kind" => "error",
               "category" => "unreadable_model_answer"
             }

      assert_exact_settlement_schema(extra_settlement)
    end

    ambiguous =
      start(
        script: [%{raw_result: {:error, :transport_timeout}}],
        bounds_token_budget: 11
      )

    {ambiguous_session, ambiguous_attachment, {:accepted, "prompt-1"}} =
      Fixture.run(ambiguous, "ambiguous")

    ambiguous_finished = await_event(ambiguous_attachment, "run.finished")

    [ambiguous_settlement] =
      ambiguous
      |> Fixture.records(ambiguous_session)
      |> records_of_kind("model_attempt_settled_v1")

    assert ambiguous_settlement["accounting"] == %{
             "source" => "estimated",
             "basis" => "remaining_allowance"
           }

    assert ambiguous_finished["outcome"] == "failed"
    refute ambiguous_finished["outcome"] in ["outcome_unknown", "bound_reached"]
    assert_exact_settlement_schema(ambiguous_settlement)

    assert_remaining_allowance(ambiguous, ambiguous_session, 11)

    for {raw_usage, category} <- [
          {%{}, "missing"},
          {%{input_tokens: 1}, "partial"},
          {:malformed_usage, "malformed"},
          {%{input_tokens: -1, output_tokens: 2}, "malformed"},
          {%{input_tokens: "1", output_tokens: 2}, "malformed"},
          {%{input_tokens: @uint64_max + 1, output_tokens: 0}, "uint64_overflow"}
        ] do
      assert_unreported_usage(raw_usage, category)
    end

    commit_unknown =
      start(
        script: [%{text: "committed once", calls: [], hold: self()}],
        bounds_token_budget: 100
      )

    {unknown_session, unknown_attachment, {:accepted, "prompt-1"}} =
      Fixture.run(commit_unknown, "re-present settlement")

    assert_receive {:holding, unknown_worker}, 5_000
    :erlang.trace(commit_unknown.store, true, [:receive])

    :ok =
      M1RuntimeTestStore.inject(
        commit_unknown.store,
        {:session_journal_commit, :after_linearization_before_result}
      )

    send(unknown_worker, :release)
    assert await_event(unknown_attachment, "run.finished")["outcome"] == "completed"

    settlement_transactions =
      traced_transactions(commit_unknown.store)
      |> Enum.filter(fn transaction ->
        Enum.any?(transaction.records, &(record_kind(&1) == "model_attempt_settled_v1"))
      end)

    assert [first_presentation, second_presentation | _rest] = settlement_transactions
    assert first_presentation == second_presentation

    assert length(
             commit_unknown
             |> Fixture.records(unknown_session)
             |> records_of_kind("model_attempt_settled_v1")
           ) == 1

    assert_abort_first_ordering()
    assert_deadline_first_ordering()
    assert_late_error_ordering()
  end

  test "recovery settles an unresolved open without redispatch and never reuses or closes the dead predecessor stream" do
    fixture =
      start(
        script: [
          %{text: "late", calls: [], deltas: ["predecessor"], hold: self()},
          %{text: "must not run", calls: [], deltas: ["successor"]}
        ],
        progress_to: self(),
        bounds_token_budget: 17
      )

    {session_id, _attachment, {:accepted, "prompt-1"}} = Fixture.run(fixture, "recover")
    assert_receive {:holding, provider_worker}, 5_000
    assert_receive {:loopex_progress, %{kind: :text_delta} = predecessor_delta}, 5_000

    coordinator = coordinator_of(fixture.runtime)
    coordinator_ref = Process.monitor(coordinator)
    worker_ref = Process.monitor(provider_worker)
    Process.exit(coordinator, :kill)
    assert_receive {:DOWN, ^coordinator_ref, :process, ^coordinator, :killed}, 5_000
    assert_receive {:DOWN, ^worker_ref, :process, ^provider_worker, _reason}, 5_000

    assert {:ok, ^session_id} =
             Loopex.resume_session(fixture.runtime, session_id,
               command_id: "resume-open-provider-attempt"
             )

    {:ok, resumed} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)
    finished = await_event(resumed, "run.finished")
    assert finished["outcome"] == "failed"
    refute finished["outcome"] in ["bound_reached", "outcome_unknown"]
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1

    records = Fixture.records(fixture, session_id)
    [settlement] = records_of_kind(records, "model_attempt_settled_v1")
    assert Enum.map(records_of_kind(records, "model_attempt_opened_v1"), & &1["attempt"]) == [1]
    assert settlement["transport"] == "dispatched_or_unknown"
    assert settlement["termination"] == "owner_loss"
    assert settlement["conversation"] == "none"
    assert settlement["next"] == "terminal"
    assert settlement["result"] == %{"kind" => "error", "category" => "model_call_failed"}

    assert settlement["accounting"] == %{
             "source" => "estimated",
             "basis" => "remaining_allowance"
           }

    assert_exact_settlement_schema(settlement)
    assert_remaining_allowance(fixture, session_id, 17)

    assert {:ok, recovered} =
             SessionState.recover(session_id, records, Fixture.events(fixture, session_id))

    refute Enum.any?(
             SessionState.elements(recovered, settlement["run_id"]),
             &assistant_element?/1
           )

    refute Enum.any?(Fixture.events(fixture, session_id), fn event ->
             public_event_kind(event) == "assistant.message_appended"
           end)

    settlement_index = record_index(records, "model_attempt_settled_v1", fn _ -> true end)
    terminal_index = record_index(records, "run_terminal_committed", fn _ -> true end)
    assert terminal_index == settlement_index + 1

    progress = receive_progress()

    refute Enum.any?(progress, fn item ->
             item.kind == :model_stream_closed and
               item.stream_domain_id == predecessor_delta.stream_domain_id
           end)

    refute Enum.any?(progress, fn item ->
             item.stream_domain_id == predecessor_delta.stream_domain_id and
               item.kind == :text_delta and item.text == "successor"
           end)
  end

  test "the durable reply retains every adapter value byte for byte and replay rebuilds none" do
    # Concept: ADR 0018 makes the durable reply the eight-key map obtained by
    # omitting only `canonical_request_bytes`, retaining the other values
    # byte-for-byte and rebuilding none of them during replay. Every other case
    # here proves the key set, which a reducer that canonicalises a value
    # satisfies unchanged. The values therefore carry deliberately mixed case, a
    # real tool call, and stream evidence that is not the non-streaming default,
    # so a mutant that rebuilds any of them cannot reproduce them.
    response_id = "RESP-MixedCase-#{System.unique_integer([:positive])}"
    text = "Mixed Case  Reply Text \u2014 \u00fcn\u00efc\u00f6d\u00e9 "
    call_id = "Call-MixedCase-Identifier"
    call_path = "Mixed/Case/Path.txt"

    identity = %{
      "provider" => "Scripted-MixedCase",
      "model" => "Model-MixedCase",
      "endpoint" => "In-Process"
    }

    fixture =
      start(
        tools: [Loopex.AgentLoopFixture.tool_definition()],
        script: [
          %{
            text: text,
            calls: [%{id: call_id, name: "write", arguments: %{"path" => call_path}}],
            deltas: ["alpha", "beta", "gamma"],
            usage: %{input_tokens: 7, output_tokens: 5},
            reply_overrides: %{
              identity: %{
                provider: "Scripted-MixedCase",
                model: "Model-MixedCase",
                endpoint: "In-Process"
              },
              provider_response_id: response_id
            }
          },
          %{text: "done", calls: []}
        ],
        bounds_token_budget: 1_000
      )

    {session_id, attachment, {:accepted, "prompt-1"}} =
      Fixture.run(fixture, "byte for byte reply")

    assert await_event(attachment, "run.finished")["outcome"] == "completed"

    records = Fixture.records(fixture, session_id)
    [settlement | _later] = records_of_kind(records, "model_attempt_settled_v1")
    assert %{"kind" => "reply", "reply" => reply} = settlement["result"]

    assert reply["text"] == text
    assert reply["provider_response_id"] == response_id
    assert reply["identity"] == identity

    assert reply["tool_calls"] == [
             %{"id" => call_id, "name" => "write", "arguments" => %{"path" => call_path}}
           ]

    assert reply["usage"] == %{"status" => "reported", "input_tokens" => 7, "output_tokens" => 5}

    assert reply["delta_count"] == 3
    assert reply["streamed"] == true
    assert reply["staged_request_digest"] == settlement["staged_request_digest"]

    refute Map.has_key?(reply, "canonical_request_bytes"),
           "the durable reply omits only canonical_request_bytes and keeps the other eight members"

    # Replay reads those bytes back. A reducer that rebuilds a member instead of
    # retaining it leaves the committed record correct and the replayed
    # conversation wrong, which every assertion above is blind to. The replayed
    # element is compared by value rather than by shape, because the conversation
    # projection is allowed its own representation - what it is not allowed to do
    # is canonicalise, truncate, or regenerate the values it carries.
    assert {:ok, recovered} =
             SessionState.recover(session_id, records, Fixture.events(fixture, session_id))

    assistant =
      recovered
      |> SessionState.elements(settlement["run_id"])
      |> Enum.find(&assistant_element?/1)

    assert assistant, "replay produced no assistant element for a settled reply"

    assert assistant.content == reply["text"],
           "replay rebuilt the reply text instead of retaining the committed bytes"

    replayed = inspect(assistant, limit: :infinity, printable_limit: :infinity)

    for retained <- [call_id, call_path, text] do
      assert String.contains?(replayed, retained),
             "replay did not retain #{inspect(retained)}; a rebuilt or canonicalised member " <>
               "cannot reproduce the committed bytes"
    end

    # Members are read by key after stringifying keys, so the projection may use
    # atom or binary keys but may not transpose, rebuild, or relocate a value.
    assert [call] = assistant.tool_calls, "replay changed the number of retained tool calls"
    call = string_keyed(call)
    assert call["id"] == call_id, "replay rebuilt the tool-call id: #{inspect(call)}"
    assert call["name"] == "write"
    assert string_keyed(call["arguments"])["path"] == call_path, "replay rebuilt the arguments"

    usage = string_keyed(assistant.usage)
    assert usage["input_tokens"] == 7, "replay rebuilt input_tokens: #{inspect(usage)}"
    assert usage["output_tokens"] == 5, "replay rebuilt output_tokens: #{inspect(usage)}"
    assert usage["status"] in ["reported", :reported], "replay dropped the usage status"
  end

  defp string_keyed(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
  defp string_keyed(other), do: other

  test "a reply whose stream evidence or digest contradicts itself is refused not repaired" do
    # Concept: ADR 0018 fixes `streamed` as true exactly when `delta_count` is
    # positive and fixes the inner `staged_request_digest` to the request it
    # answers. A reducer that derives one member from the other produces the
    # right value whenever the adapter was consistent, so retention and
    # derivation are indistinguishable there. They separate only when the adapter
    # contradicts itself: retention must refuse the malformed reply as
    # `dispatched_or_unknown` with no retry, while derivation would silently
    # repair it and continue.
    contradictions = [
      {:streamed_without_deltas, %{delta_count: 0, streamed: true}},
      {:deltas_without_streamed, %{delta_count: 3, streamed: false}},
      {:foreign_digest, %{staged_request_digest: String.duplicate("0", 64)}}
    ]

    for {label, overrides} <- contradictions do
      fixture =
        start(
          script: [
            %{text: "contradicted #{label}", calls: [], reply_overrides: overrides},
            %{text: "must not retry", calls: []}
          ],
          bounds_token_budget: 100
        )

      {session_id, attachment, {:accepted, "prompt-1"}} = Fixture.run(fixture, "#{label}")
      finished = await_event(attachment, "run.finished")

      assert finished["outcome"] == "failed",
             "#{label}: a self-contradicting reply was repaired into #{inspect(finished["outcome"])}"

      assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1,
             "#{label}: a reply after a possible send was retried"

      records = Fixture.records(fixture, session_id)
      [settlement] = records_of_kind(records, "model_attempt_settled_v1")
      assert settlement["transport"] == "dispatched_or_unknown"
      assert %{"kind" => "error"} = settlement["result"]

      refute Enum.any?(Fixture.events(fixture, session_id), fn event ->
               public_event_kind(event) == "assistant.message_appended"
             end),
             "#{label}: a refused reply entered the conversation"
    end
  end

  defp queue_provider_permit_request(fixture, content) do
    {:ok, %{control: control}} = Runtime.children(fixture.runtime)
    :erlang.trace(control, true, [:send, :receive])

    :ok =
      M1RuntimeTestStore.hold_next_record_before_linearization(
        fixture.store,
        "model_attempt_opened_v1",
        self()
      )

    {session_id, attachment, {:accepted, "prompt-1"}} = Fixture.run(fixture, content)

    assert_receive {:record_held_before_linearization, waiter, _store, "model_attempt_opened_v1",
                    transaction},
                   5_000

    assert Enum.map(transaction.records, &record_kind/1) == [
             "model_request_committed",
             "model_attempt_opened_v1"
           ]

    [request_record, opened] = transaction.records
    binding = Map.put(attempt_identity(opened), "session_id", session_id)
    coordinator = coordinator_of(fixture.runtime)

    suspend_process(control)
    M1RuntimeTestStore.release(waiter)

    {control_message, control_request, worker} =
      advance_to_queued_provider_request(
        fixture.runtime,
        control,
        coordinator,
        binding
      )

    assert coherent_attempt_binding!(control_request, binding) == binding
    assert contains_exact?(control_request, coordinator)
    assert contains_exact?(control_request, worker)
    [permit_reference] = references(control_request) |> MapSet.to_list()

    %{
      fixture: fixture,
      session_id: session_id,
      attachment: attachment,
      request_record: request_record,
      opened: opened,
      binding: binding,
      coordinator: coordinator,
      control: control,
      control_message: control_message,
      control_request: control_request,
      worker: worker,
      permit_reference: permit_reference
    }
  end

  defp advance_to_queued_provider_request(
         runtime,
         control,
         coordinator,
         binding,
         attempts \\ 20
       )

  defp advance_to_queued_provider_request(
         _runtime,
         _control,
         _coordinator,
         _binding,
         0
       ),
       do: flunk("Control never queued the exact provider-permit request")

  defp advance_to_queued_provider_request(
         runtime,
         control,
         coordinator,
         binding,
         attempts
       ) do
    # Concept: releasing Control to drain one message also releases any
    # provider-permit request already queued behind it, which would send the
    # permit the caller is about to prove was never sent. The coordinator is the
    # only source of that request, so suspending it first and re-scanning the
    # whole mailbox makes the drain window provably empty of permit requests
    # rather than merely usually empty.
    case queued_provider_request(runtime, control, binding) do
      {:ok, found} ->
        found

      :error ->
        # A queued call must exist before the coordinator is frozen, or the
        # coordinator can never issue the request this loop is waiting for.
        _queued = await_queued_control_call(control)
        suspend_process(coordinator)

        case queued_provider_request(runtime, control, binding) do
          {:ok, found} ->
            resume_process(coordinator)
            found

          :error ->
            drain_one_control_call(control)
            resume_process(coordinator)

            advance_to_queued_provider_request(
              runtime,
              control,
              coordinator,
              binding,
              attempts - 1
            )
        end
    end
  end

  # Concept: the permit request may sit anywhere in Control's mailbox, not only
  # at its head. Scanning only the head made the caller drain a message it did
  # not need to drain.
  defp queued_provider_request(runtime, control, binding) do
    Enum.reduce_while(queued_control_calls(control), :error, fn
      {:"$gen_call", _from, request} = message, _acc ->
        case provider_worker_in_request(runtime, request, binding) do
          {:ok, worker} -> {:halt, {:ok, {message, request, worker}}}
          :error -> {:cont, :error}
        end
    end)
  end

  defp drain_one_control_call(control) do
    control_message = await_queued_control_call(control)
    resume_process(control)
    await_control_call_consumed(control, control_message)
    suspend_process(control)
    :ok
  end

  defp provider_worker_in_request(runtime, request, binding) do
    workers = owner_worker_pids(runtime)

    case Enum.filter(workers, &contains_exact?(request, &1)) do
      [worker] ->
        if coherent_attempt_bindings(request, binding) != [], do: {:ok, worker}, else: :error

      _other ->
        :error
    end
  end

  defp owner_worker_pids(runtime) do
    {:ok, %{owner_groups: owner_groups}} = Runtime.children(runtime)

    owner_groups
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn
      {_id, group, :worker, _modules} when is_pid(group) ->
        case Loopex.Runtime.OwnerGroup.workers(group) do
          {:ok, workers} -> Task.Supervisor.children(workers)
          _unavailable -> []
        end

      _other ->
        []
    end)
  end

  defp await_queued_control_call(control, attempts \\ 1_000)
  defp await_queued_control_call(_control, 0), do: flunk("Control received no queued call")

  defp await_queued_control_call(control, attempts) do
    case queued_control_calls(control) do
      [call | _rest] ->
        call

      [] ->
        Process.sleep(5)
        await_queued_control_call(control, attempts - 1)
    end
  end

  defp await_control_call_consumed(control, message, attempts \\ 1_000)

  defp await_control_call_consumed(_control, _message, 0),
    do: flunk("Control did not consume its queued call")

  defp await_control_call_consumed(control, message, attempts) do
    if Enum.any?(queued_control_calls(control), &(&1 === message)) do
      Process.sleep(5)
      await_control_call_consumed(control, message, attempts - 1)
    else
      :ok
    end
  end

  defp await_control_permit(control, worker, binding, attempts \\ 1_000)

  defp await_control_permit(_control, _worker, _binding, 0),
    do: flunk("Control never sent the exact provider permit directly to its worker")

  defp await_control_permit(control, worker, binding, attempts) do
    receive do
      {:trace, ^control, :send, permit, ^worker} ->
        assert coherent_attempt_binding!(permit, binding) == binding
        permit
    after
      5 -> await_control_permit(control, worker, binding, attempts - 1)
    end
  end

  defp retarget_permit(permit, source, target) do
    source_container = coherent_attempt_binding_container!(permit, source.binding)

    target_container =
      Map.new(source_container, fn {key, value} ->
        normalized_key = if is_atom(key) or is_binary(key), do: to_string(key), else: key

        if Map.has_key?(target.binding, normalized_key),
          do: {key, Map.fetch!(target.binding, normalized_key)},
          else: {key, value}
      end)

    permit
    |> replace_exact(source_container, target_container)
    |> replace_exact(source.worker, target.worker)
    |> replace_exact(source.permit_reference, target.permit_reference)
  end

  defp replace_binding_field(term, expected, field, replacement) do
    container = coherent_attempt_binding_container!(term, expected)

    changed =
      Map.new(container, fn {key, value} ->
        normalized_key = if is_atom(key) or is_binary(key), do: to_string(key), else: key
        if normalized_key == field, do: {key, replacement}, else: {key, value}
      end)

    refute changed == container
    replace_exact(term, container, changed)
  end

  defp exercise_retry_succession(position) do
    fixture =
      start(
        script: [
          %{raw_result: {:error, {:not_dispatched, "model_call_failed"}}},
          %{text: "attempt two", calls: [], usage: %{input_tokens: 3, output_tokens: 2}},
          %{text: "attempt three must not run", calls: []}
        ]
      )

    :ok =
      M1RuntimeTestStore.delay_after_record(
        fixture.store,
        "model_attempt_settled_v1",
        self()
      )

    {session_id, _attachment, {:accepted, "prompt-1"}} =
      Fixture.run(fixture, "retry across succession")

    assert_receive {:record_linearized, settlement_waiter, _store, "model_attempt_settled_v1",
                    _transition, {:committed, _tx_id, _receipt}},
                   5_000

    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 1

    case position do
      :between_attempts ->
        assert {:ok, ^session_id} =
                 Loopex.resume_session(fixture.runtime, session_id,
                   command_id: "resume-between-attempts"
                 )

        M1RuntimeTestStore.release(settlement_waiter)

      :after_attempt_two_open ->
        :ok =
          M1RuntimeTestStore.delay_after_record(
            fixture.store,
            "model_attempt_opened_v1",
            self()
          )

        M1RuntimeTestStore.release(settlement_waiter)

        assert_receive {:record_linearized, open_waiter, _store, "model_attempt_opened_v1",
                        _transition, {:committed, _open_tx_id, _open_receipt}},
                       5_000

        assert Enum.map(
                 fixture
                 |> Fixture.records(session_id)
                 |> records_of_kind("model_attempt_opened_v1"),
                 & &1["attempt"]
               ) == [1, 2]

        assert {:ok, ^session_id} =
                 Loopex.resume_session(fixture.runtime, session_id,
                   command_id: "resume-after-attempt-two-open"
                 )

        M1RuntimeTestStore.release(open_waiter)
    end

    {:ok, resumed} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)
    finished = await_event(resumed, "run.finished")
    records = Fixture.records(fixture, session_id)

    %{
      provider_calls: length(AgentLoopTestModel.dispatched(fixture.model)),
      finished: finished,
      opens: records_of_kind(records, "model_attempt_opened_v1"),
      settlements: records_of_kind(records, "model_attempt_settled_v1")
    }
  end

  defp exercise_control_loss(loss, phase) do
    label = "#{loss}-#{phase}"

    fixture =
      start(
        script: [
          %{
            text: "predecessor",
            calls: [],
            deltas: [label],
            hold: self(),
            hold_timeout_ms: 30_000
          },
          %{text: "must not run", calls: [], deltas: ["successor"]}
        ],
        progress_to: self(),
        bounds_token_budget: 101
      )

    attempt = queue_provider_permit_request(fixture, label)

    predecessor_domain =
      StreamDomain.derive(
        :model,
        attempt.session_id,
        attempt.opened["operation_id"],
        attempt.opened["attempt"]
      )

    case {loss, phase} do
      {:control_death, :before_send} ->
        Process.exit(attempt.control, :kill)

      {:control_death, :after_send} ->
        resume_process(attempt.control)

        _permit =
          await_control_permit(attempt.control, attempt.worker, attempt.binding)

        worker = attempt.worker
        assert_receive {:holding, ^worker}, 5_000
        Process.exit(attempt.control, :kill)

      {:lost_reply, :before_send} ->
        suspend_process(attempt.coordinator)
        Process.exit(attempt.worker, :kill)
        await_process_down(attempt.worker)
        resume_process(attempt.control)
        await_control_call_consumed(attempt.control, attempt.control_message)
        worker = attempt.worker
        control = attempt.control
        refute_receive {:trace, ^control, :send, _permit, ^worker}, 50
        Process.exit(attempt.coordinator, :kill)

      {:lost_reply, :after_send} ->
        suspend_process(attempt.coordinator)
        resume_process(attempt.control)

        _permit =
          await_control_permit(attempt.control, attempt.worker, attempt.binding)

        worker = attempt.worker
        assert_receive {:holding, ^worker}, 5_000
        await_control_call_consumed(attempt.control, attempt.control_message)
        Process.exit(attempt.coordinator, :kill)
    end

    await_process_down(attempt.coordinator)
    await_process_down(attempt.worker)

    if loss == :control_death do
      _new_control = await_restarted_control(fixture.runtime, attempt.control)
    end

    assert {:ok, attempt.session_id} ==
             Loopex.resume_session(fixture.runtime, attempt.session_id,
               command_id: "resume-#{label}"
             )

    {:ok, resumed} = Loopex.attach(fixture.runtime, attempt.session_id, after_event_sequence: 0)
    finished = await_event(resumed, "run.finished")
    records = Fixture.records(fixture, attempt.session_id)

    %{
      provider_calls: length(AgentLoopTestModel.dispatched(fixture.model)),
      finished: finished,
      opens: records_of_kind(records, "model_attempt_opened_v1"),
      settlements: records_of_kind(records, "model_attempt_settled_v1"),
      progress: receive_progress(),
      predecessor_domain: predecessor_domain
    }
  end

  defp exercise_live_handoff(:before_send) do
    fixture =
      start(
        script: [
          %{text: "predecessor must not run", calls: []},
          %{text: "successor must not run", calls: []}
        ],
        bounds_token_budget: 107
      )

    {:ok, %{control: control}} = Runtime.children(fixture.runtime)
    :erlang.trace(control, true, [:send, :receive])

    :ok =
      M1RuntimeTestStore.delay_after_record(
        fixture.store,
        "model_attempt_opened_v1",
        self()
      )

    {session_id, _attachment, {:accepted, "prompt-1"}} =
      Fixture.run(fixture, "handoff before permit")

    assert_receive {:record_linearized, open_waiter, _store, "model_attempt_opened_v1",
                    _transition, {:committed, _tx_id, _receipt}},
                   5_000

    [opened] =
      fixture
      |> Fixture.records(session_id)
      |> records_of_kind("model_attempt_opened_v1")

    binding = Map.put(attempt_identity(opened), "session_id", session_id)
    predecessor = coordinator_of(fixture.runtime)

    # ADR 0018: after its open record commits, the predecessor makes exactly two Control
    # calls before it can ask for a permit -- the publication fence, then the ownership
    # re-read. Neither can be queued alongside the permit request, so both are answered
    # here, while the predecessor is still Control's current owner and therefore gets
    # `:ok` rather than `:superseded_owner`; the permit request it finally issues is then
    # a real one for the handoff below to overtake. The exact pair is asserted, so a
    # production change to that sequence fails here rather than silently mis-sequencing
    # the cell into the `:after_send` case.
    suspend_process(control)
    M1RuntimeTestStore.release(open_waiter)

    for {expected, thaw_predecessor?} <- [{:post_commit, true}, {:current_owner, false}] do
      [{:"$gen_call", _from, request} = call] = await_queued_control_calls(control, 1)
      assert elem(request, 0) == expected

      # The predecessor is blocked inside this exact call, so freezing it here is
      # race-free: it cannot issue its permit request during the drain window.
      suspend_process(predecessor)
      resume_process(control)
      await_control_call_consumed(control, call)
      suspend_process(control)
      if thaw_predecessor?, do: resume_process(predecessor)
    end

    # ADR 0008: Control registers the successor when it acquires the owner, before
    # `advance_owner` linearizes, so queueing the acquisition ahead of the thawed
    # predecessor's permit request is what puts the handoff first.
    resume =
      Task.async(fn ->
        Loopex.resume_session(fixture.runtime, session_id,
          command_id: "resume-before-provider-permit"
        )
      end)

    [_successor_acquisition] = await_queued_control_calls(control, 1)
    resume_process(predecessor)

    {provider_message, _provider_request, worker} =
      await_queued_provider_call(fixture.runtime, control, binding)

    queued = await_queued_control_calls(control, 2)
    assert Enum.find_index(queued, &(&1 === provider_message)) > 0
    resume_process(control)

    assert {:ok, ^session_id} = Task.await(resume, 5_000)
    refute_receive {:trace, ^control, :send, _permit, ^worker}, 50
    await_process_down(predecessor)

    finish_live_handoff(fixture, session_id)
  end

  defp exercise_live_handoff(:after_send) do
    fixture =
      start(
        script: [
          %{
            text: "predecessor call",
            calls: [],
            deltas: ["predecessor"],
            hold: self(),
            hold_timeout_ms: 30_000
          },
          %{text: "successor must not run", calls: []}
        ],
        progress_to: self(),
        bounds_token_budget: 109
      )

    attempt = queue_provider_permit_request(fixture, "handoff after permit")
    resume_process(attempt.control)
    _permit = await_control_permit(attempt.control, attempt.worker, attempt.binding)
    worker = attempt.worker
    assert_receive {:holding, ^worker}, 5_000

    assert {:ok, attempt.session_id} ==
             Loopex.resume_session(fixture.runtime, attempt.session_id,
               command_id: "resume-after-provider-permit"
             )

    if Process.alive?(worker), do: send(worker, :release)
    await_process_down(attempt.coordinator)

    finish_live_handoff(fixture, attempt.session_id)
  end

  defp finish_live_handoff(fixture, session_id) do
    {:ok, resumed} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)
    finished = await_event(resumed, "run.finished")
    records = Fixture.records(fixture, session_id)

    %{
      provider_calls: length(AgentLoopTestModel.dispatched(fixture.model)),
      finished: finished,
      opens: records_of_kind(records, "model_attempt_opened_v1"),
      settlements: records_of_kind(records, "model_attempt_settled_v1")
    }
  end

  defp await_queued_provider_call(runtime, control, binding, attempts \\ 1_000)

  defp await_queued_provider_call(_runtime, _control, _binding, 0),
    do: flunk("the predecessor never queued its exact provider-permit request")

  defp await_queued_provider_call(runtime, control, binding, attempts) do
    result =
      control
      |> queued_control_calls()
      |> Enum.find_value(fn {:"$gen_call", _from, request} = message ->
        case provider_worker_in_request(runtime, request, binding) do
          {:ok, worker} -> {message, request, worker}
          :error -> nil
        end
      end)

    case result do
      nil ->
        Process.sleep(5)
        await_queued_provider_call(runtime, control, binding, attempts - 1)

      provider ->
        provider
    end
  end

  defp await_queued_control_calls(control, minimum, attempts \\ 1_000)

  defp await_queued_control_calls(_control, _minimum, 0),
    do: flunk("Control did not receive the required queued calls")

  defp await_queued_control_calls(control, minimum, attempts) do
    calls = queued_control_calls(control)

    if length(calls) >= minimum do
      calls
    else
      Process.sleep(5)
      await_queued_control_calls(control, minimum, attempts - 1)
    end
  end

  # Concept: what Control is still holding, read from delivery and answer rather
  # than from a mailbox that may be unable to answer for itself.
  #
  # Technical depth: `Process.info(pid, :messages)` and `:message_queue_len` report a
  # process's internal message queue. A message sent to a process frozen by
  # `:erlang.suspend_process/1` can still be sitting in that process's outer signal
  # queue, which is merged into the internal queue only when the process is scheduled
  # again, so a frozen Control can read as holding nothing while a call has in fact
  # been delivered and is waiting. That was proved here: at the failure the
  # coordinator sat blocked in `Loopex.Runtime.Control.post_commit/5` while Control
  # reported `{:messages, []}` and `{:message_queue_len, 0}`, and thawing Control
  # answered that same call inside 200ms. The same absence is therefore never
  # evidence that a call is gone, which is why nothing here removes a call because a
  # mailbox read did not show it.
  #
  # A call is queued once its `:receive` trace has arrived and stays queued until
  # Control's own reply to that exact call is traced -- `{Tag, Reply}` carrying the
  # `$gen_call`'s unique tag, which no permit send can imitate, so the `:send` traces
  # the cells match on are left alone. Both trace points fire while the target stays
  # frozen. A live mailbox read is still unioned in, because a call it does show is
  # certainly there; it can only add.
  #
  # Every cell that uses these helpers already traces its own Control with
  # `[:send, :receive]` from this same process, so nothing here enables, clears, or
  # reassigns a trace flag.
  defp queued_control_calls(control) do
    if Process.alive?(control) do
      outstanding = sync_delivery_ledger(control)

      outstanding ++
        Enum.reject(
          mailbox_control_calls(control),
          fn seen -> Enum.any?(outstanding, &(&1 === seen)) end
        )
    else
      put_delivery_ledger(control, [])
      []
    end
  end

  defp sync_delivery_ledger(control) do
    outstanding =
      control
      |> drain_delivery_traces(delivery_ledger(control))
      |> Enum.reject(&answered?(control, &1))

    put_delivery_ledger(control, outstanding)
    outstanding
  end

  defp drain_delivery_traces(control, acc) do
    receive do
      {:trace, ^control, :receive, {:"$gen_call", _from, _request} = message} ->
        drain_delivery_traces(control, acc ++ [message])

      {:trace, ^control, :receive, _other} ->
        drain_delivery_traces(control, acc)
    after
      0 -> acc
    end
  end

  defp answered?(control, {:"$gen_call", {_caller, tag}, _request}) do
    receive do
      {:trace, ^control, :send, {^tag, _reply}, _target} -> true
    after
      0 -> false
    end
  end

  defp answered?(_control, _message), do: false

  defp delivery_ledger(control),
    do: Process.get(@delivery_ledger, %{}) |> Map.get(control, [])

  defp put_delivery_ledger(control, messages) do
    Process.put(@delivery_ledger, Map.put(Process.get(@delivery_ledger, %{}), control, messages))
    :ok
  end

  defp mailbox_control_calls(control) do
    case Process.info(control, :messages) do
      {:messages, messages} ->
        Enum.filter(messages, fn
          {:"$gen_call", _from, _request} -> true
          _other -> false
        end)

      _dead ->
        []
    end
  end

  defp exercise_deadline_cell(phase) do
    # Concept: the :after_send cell needs the permit sent before the committed
    # deadline elapses. A one-second budget raced this fixture's own setup - a
    # store hold round-trip, a suspend, and a mailbox scan - so on a loaded box
    # Control took the pre-send branch and the case failed against a correct
    # implementation. Setup is bounded only by its own loud failures, so it can
    # in principle outlast any fixed budget; the cell therefore checks the
    # deadline once, before the permit is released and with the coordinator
    # frozen, so a stalled setup fails here by name rather than being read as
    # the pre-send branch. The deadline is crossed deliberately below.
    deadline_ms = if phase == :before_send, do: 200, else: 10_000

    fixture =
      start(
        script: [
          %{
            text: "late reply",
            calls: [],
            deltas: [Atom.to_string(phase)],
            hold: self(),
            hold_timeout_ms: 30_000
          },
          %{text: "must not retry", calls: []}
        ],
        progress_to: self(),
        bounds_deadline_ms: deadline_ms,
        bounds_token_budget: 103
      )

    attempt = queue_provider_permit_request(fixture, "deadline #{phase}")

    case phase do
      :before_send ->
        wait_past_deadline(committed_deadline!(attempt.request_record))
        resume_process(attempt.control)

      :after_send ->
        # Concept: the run deadline reaches the coordinator as a message, and a
        # suspended process drains nothing - not even a message already in its
        # mailbox. Freezing the coordinator before the permit is delivered
        # therefore makes "permit first, deadline second" an ordering this case
        # establishes, exactly as the :before_send cell freezes Control to
        # establish the opposite one. Control sends the permit directly to the
        # worker, so the frozen coordinator is not needed for the send. Waiting
        # past the deadline while it is frozen can only take longer, never
        # shorter, and the deadline is acted on only once the case resumes it.
        deadline = committed_deadline!(attempt.request_record)
        suspend_process(attempt.coordinator)

        assert System.system_time(:millisecond) < deadline,
               "setup outlasted the committed deadline before the permit was released; " <>
                 "this cell has not observed a post-send deadline"

        resume_process(attempt.control)
        _permit = await_control_permit(attempt.control, attempt.worker, attempt.binding)
        worker = attempt.worker

        # The provider holding is the causal proof that the permit won: a deadline
        # reached before the send makes Control refuse and this message never
        # arrives, which fails here loudly. No wall-clock comparison is made in
        # this process, because one taken after the permit could only fail a
        # correct implementation that had already won.
        assert_receive {:holding, ^worker}, 5_000

        wait_past_deadline(deadline)
        resume_process(attempt.coordinator)
    end

    finished = await_event(attempt.attachment, "run.finished")
    records = Fixture.records(fixture, attempt.session_id)

    if phase == :before_send do
      worker = attempt.worker
      control = attempt.control
      refute_receive {:trace, ^control, :send, _permit, ^worker}, 50
    end

    %{
      provider_calls: length(AgentLoopTestModel.dispatched(fixture.model)),
      finished: finished,
      opens: records_of_kind(records, "model_attempt_opened_v1"),
      settlements: records_of_kind(records, "model_attempt_settled_v1")
    }
  end

  defp committed_deadline!(request_record) do
    deadlines =
      request_record
      |> maps()
      |> Enum.flat_map(fn map ->
        Enum.flat_map(map, fn {key, value} ->
          normalized_key = if is_atom(key) or is_binary(key), do: to_string(key), else: key

          if normalized_key == "deadline" and is_integer(value),
            do: [value],
            else: []
        end)
      end)
      |> Enum.uniq()

    case deadlines do
      [deadline] -> deadline
      [] -> flunk("the committed request carries no absolute deadline")
      _many -> flunk("the committed request carries competing absolute deadlines")
    end
  end

  defp wait_past_deadline(deadline) do
    if System.system_time(:millisecond) >= deadline do
      :ok
    else
      Process.sleep(5)
      wait_past_deadline(deadline)
    end
  end

  # Concept: the freeze this fixture asks for is the freeze it gets, whatever the
  # scheduler reports at that instant.
  #
  # Technical depth: these helpers used to skip the suspend, or the resume, when
  # `Process.info(pid, :status)` disagreed with the freeze being asked for, which
  # let a scheduler observation decide whether a freeze happened at all. The freeze
  # is no longer inferred from the scheduler: this process records what it has
  # suspended and issues one suspend and one resume to match, which is the pairing
  # `:erlang.suspend_process/1` itself counts. `drain_one_control_call/1` re-freezes
  # through these same helpers and needs no separate bookkeeping.
  #
  # There is deliberately no `on_exit` resume. It would run in a process that never
  # suspended the target, where `:erlang.resume_process/1` raises, and the BEAM
  # already releases a suspension when its suspender exits, so the callback was
  # either a no-op or a crash and never cleanup.
  @frozen_processes :provider_attempt_frozen_processes

  defp suspend_process(pid) do
    frozen = Process.get(@frozen_processes, %{})

    if Map.get(frozen, pid, false) do
      :ok
    else
      true = :erlang.suspend_process(pid)
      Process.put(@frozen_processes, Map.put(frozen, pid, true))
      :ok
    end
  end

  defp resume_process(pid) do
    frozen = Process.get(@frozen_processes, %{})

    if Map.get(frozen, pid, false) do
      if Process.alive?(pid) do
        true = :erlang.resume_process(pid)
      end

      Process.put(@frozen_processes, Map.put(frozen, pid, false))
    end

    :ok
  end

  defp await_process_down(pid, attempts \\ 1_000)
  defp await_process_down(_pid, 0), do: flunk("process did not stop")

  defp await_process_down(pid, attempts) do
    if Process.alive?(pid) do
      Process.sleep(5)
      await_process_down(pid, attempts - 1)
    else
      :ok
    end
  end

  defp hold_commit_unknown_replay(store, kind, first_waiter, first_transaction) do
    :ok =
      M1RuntimeTestStore.inject(
        store,
        {:session_journal_commit, :after_linearization_before_result}
      )

    :ok = M1RuntimeTestStore.hold_next_record_before_linearization(store, kind, self())
    M1RuntimeTestStore.release(first_waiter)

    assert_receive {:record_held_before_linearization, replay_waiter, ^store, ^kind,
                    replay_transaction},
                   5_000

    assert replay_transaction == first_transaction
    replay_waiter
  end

  defp await_restarted_control(runtime, old_control, attempts \\ 1_000)
  defp await_restarted_control(_runtime, _old_control, 0), do: flunk("Control did not restart")

  defp await_restarted_control(runtime, old_control, attempts) do
    case Runtime.children(runtime) do
      {:ok, %{control: control}} when is_pid(control) and control != old_control ->
        control

      _not_ready ->
        Process.sleep(5)
        await_restarted_control(runtime, old_control, attempts - 1)
    end
  end

  defp start(options) do
    options =
      options
      |> Keyword.put_new(:tools, [])
      |> Keyword.put_new(:runtime_id, "provider-attempt-#{System.unique_integer([:positive])}")

    fixture =
      options |> Fixture.start() |> Map.put(:runtime_id, Keyword.fetch!(options, :runtime_id))

    fixture =
      cond do
        Keyword.get(options, :record_page_size_one, false) ->
          restart_with_page_size_one_store(fixture, options)

        Keyword.has_key?(options, :model_module) ->
          restart_with_model(fixture, options)

        true ->
          fixture
      end

    on_exit(fn -> Fixture.stop(fixture) end)
    fixture
  end

  defp restart_with_page_size_one_store(fixture, options) do
    :ok = Loopex.stop(fixture.runtime)
    {:ok, backing_store} = Store.new(M1RuntimeTestStore, fixture.store)
    {:ok, page_one_store} = Store.new(ProviderAttemptPageOneStore, {backing_store, self()})

    {:ok, runtime} =
      Loopex.start_link(
        context_token_budget: 8_192,
        runtime_id: Keyword.fetch!(options, :runtime_id),
        store: page_one_store,
        progress_to: Keyword.get(options, :progress_to),
        diagnostics_to: Keyword.get(options, :diagnostics_to),
        model: %{
          module: AgentLoopTestModel,
          model: "scripted:v1",
          options: [script: fixture.model, max_tokens: Keyword.get(options, :max_tokens, 256)]
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
        bounds: %{
          max_turns: Keyword.get(options, :bounds_max_turns, 8),
          token_budget: Keyword.get(options, :bounds_token_budget, 1_000_000),
          deadline_ms: Keyword.get(options, :bounds_deadline_ms, 600_000)
        },
        project_manifest: Keyword.get(options, :project_manifest),
        project_decision: Keyword.get(options, :project_decision),
        tools: fixture.definitions,
        active_tools: Enum.map(fixture.definitions, &Map.fetch!(&1, "tool_id")),
        policy: Keyword.get(options, :policy, Loopex.AgentLoopTestPolicy),
        grant_decision: {:host_policy, :allow}
      )

    %{fixture | runtime: runtime}
  end

  defp restart_with_model(fixture, options) do
    :ok = Loopex.stop(fixture.runtime)
    {:ok, store} = Store.new(M1RuntimeTestStore, fixture.store)
    model_module = Keyword.fetch!(options, :model_module)

    {:ok, runtime} =
      Loopex.start_link(
        context_token_budget: 8_192,
        runtime_id: Keyword.fetch!(options, :runtime_id),
        store: store,
        progress_to: Keyword.get(options, :progress_to),
        diagnostics_to: Keyword.get(options, :diagnostics_to),
        model: %{
          module: model_module,
          model: "scripted:v1",
          options: [observer: self(), max_tokens: Keyword.get(options, :max_tokens, 256)]
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
        bounds: %{
          max_turns: Keyword.get(options, :bounds_max_turns, 8),
          token_budget: Keyword.get(options, :bounds_token_budget, 1_000_000),
          deadline_ms: Keyword.get(options, :bounds_deadline_ms, 600_000)
        },
        project_manifest: Keyword.get(options, :project_manifest),
        project_decision: Keyword.get(options, :project_decision),
        tools: fixture.definitions,
        active_tools: Enum.map(fixture.definitions, &Map.fetch!(&1, "tool_id")),
        policy: Keyword.get(options, :policy, Loopex.AgentLoopTestPolicy),
        grant_decision: {:host_policy, :allow}
      )

    %{fixture | runtime: runtime}
  end

  defp only_session_id(fixture) do
    case fixture.store
         |> M1RuntimeTestStore.inspect_state()
         |> Map.fetch!(:sessions)
         |> Map.keys() do
      [session_id] -> {:ok, session_id}
      _other -> {:error, :not_exactly_one_session}
    end
  end

  defp flush_record_pages do
    receive do
      {:provider_attempt_record_page, _after_version, _result} -> flush_record_pages()
    after
      0 -> :ok
    end
  end

  defp receive_record_pages(acc \\ []) do
    receive do
      {:provider_attempt_record_page, after_version, {:ok, rows}} ->
        receive_record_pages([{after_version, rows} | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  # Concept: an adapter answer no record could ever hold is refused before it is
  # read, not after it has been copied.
  #
  # Technical depth: `attempt_result/3` canonicalizes the raw answer before any
  # Store bound applies, and the projection visits every member of the reply's
  # collections. An adapter returning a million tool calls was therefore fully
  # traversed and projected into a million fresh maps, and the settlement built
  # from it only then failed to fit. ADR 0017's cardinality ceiling already
  # decides the question -- a collection above 1,024 members can never be
  # admitted into any item -- so it is applied to the raw collections first and
  # the answer becomes ADR 0018 combination 5's `unreadable_model_answer`.
  test "an adapter reply above the item cardinality ceiling is refused without projecting it" do
    request = %{
      canonical_request_bytes: "canonical-request-bytes",
      staged_request_digest: String.duplicate("d", 64)
    }

    call = %{"id" => "call-1", "name" => "tool", "arguments" => %{}}
    raw = adapter_reply(request, List.duplicate(call, 1_000_000))

    :erlang.garbage_collect()
    {:memory, before} = Process.info(self(), :memory)
    result = ProviderAttempt.canonical_reply(raw, request)
    {:memory, after_projection} = Process.info(self(), :memory)

    assert result == {:error, :unreadable_model_answer}
    assert after_projection - before < 16 * 1024 * 1024

    wide_usage =
      Map.new(1..(@record_cardinality_limit + 1), fn index -> {"member-#{index}", index} end)

    assert ProviderAttempt.canonical_reply(Map.put(raw, "usage", wide_usage), request) ==
             {:error, :unreadable_model_answer}

    wide_reply = Map.new(1..(@record_cardinality_limit + 1), fn i -> {"member-#{i}", i} end)

    assert ProviderAttempt.canonical_reply(wide_reply, request) ==
             {:error, :unreadable_model_answer}

    assert {:ok, projected} =
             ProviderAttempt.canonical_reply(adapter_reply(request, [call]), request)

    assert projected["tool_calls"] == [call]
  end

  # Concept: a settlement is valid when it is one of the combinations ADR 0018
  # lists, not when it avoids the ones somebody remembered to forbid.
  #
  # Technical depth: the verdict was checked as a blacklist, so every member
  # assignment nobody had enumerated validated by default. An attempt-one
  # settlement with exact `not_dispatched` transport, no termination, no
  # conversation and no accounting validated with `next: "terminal"`, although
  # combination 4 fixes `retry` for exactly that cell -- history that skips the
  # allowance version 1 grants. Every cell of the closed table is enumerated
  # here against every other assignment of the same members, so a combination
  # the ADR does not list is invalid because it is not listed.
  test "exactly the ADR 0018 settlement combinations validate" do
    valid = valid_settlement_cells()

    reviewers_example =
      settlement_record(1, "not_dispatched", nil, :failed, "none", "terminal", :none)

    assert ProviderAttempt.validate_settled(reviewers_example) ==
             {:error, :invalid_attempt_settlement}

    assert ProviderAttempt.validate_settled(
             settlement_record(1, "not_dispatched", nil, :failed, "none", "retry", :none)
           ) == :ok

    for attempt <- [1, 2],
        transport <- ["not_dispatched", "dispatched_or_unknown"],
        termination <- [nil, "abort", "deadline", "owner_loss"],
        result_tag <- settlement_result_tags(),
        conversation <- ["canonical", "evidence_only", "none"],
        next <- ["retry", "continue", "terminal"],
        accounting_tag <- settlement_accounting_tags() do
      cell = {attempt, transport, termination, result_tag, conversation, next, accounting_tag}

      record =
        settlement_record(
          attempt,
          transport,
          termination,
          result_tag,
          conversation,
          next,
          accounting_tag
        )

      expected =
        if MapSet.member?(valid, cell), do: :ok, else: {:error, :invalid_attempt_settlement}

      assert ProviderAttempt.validate_settled(record) == expected,
             "settlement cell #{inspect(cell)} expected #{inspect(expected)}"
    end
  end

  # The closed table of ADR 0018, transcribed as the cells it lists rather than
  # derived from the module under test.
  defp valid_settlement_cells do
    attempts = [1, 2]
    replies = [:reply_tools_reported, :reply_tools_bare, :reply_plain_reported, :reply_plain_bare]

    combination_one =
      for attempt <- attempts, reply <- replies do
        {attempt, "dispatched_or_unknown", nil, reply, "canonical", settlement_reply_next(reply),
         settlement_reply_accounting(reply)}
      end

    combination_two =
      for attempt <- attempts, termination <- ["abort", "deadline"], reply <- replies do
        {attempt, "dispatched_or_unknown", termination, reply, "evidence_only", "terminal",
         settlement_reply_accounting(reply)}
      end

    combination_three =
      for attempt <- attempts, termination <- [nil, "abort", "deadline", "owner_loss"] do
        {attempt, "dispatched_or_unknown", termination, :failed, "none", "terminal", :estimated}
      end

    combination_four =
      for attempt <- attempts, termination <- [nil, "abort", "deadline"] do
        next = if attempt == 1 and is_nil(termination), do: "retry", else: "terminal"
        {attempt, "not_dispatched", termination, :failed, "none", next, :none}
      end

    combination_five =
      for attempt <- attempts,
          termination <- [nil, "abort", "deadline"],
          accounting <- [:reported_pair, :reported_other, :estimated] do
        {attempt, "dispatched_or_unknown", termination, :unreadable, "none", "terminal",
         accounting}
      end

    MapSet.new(
      combination_one ++
        combination_two ++
        combination_three ++
        combination_four ++
        combination_five
    )
  end

  defp settlement_reply_next(reply)
       when reply in [:reply_tools_reported, :reply_tools_bare],
       do: "continue"

  defp settlement_reply_next(_reply), do: "terminal"

  defp settlement_reply_accounting(reply)
       when reply in [:reply_tools_reported, :reply_plain_reported],
       do: :reported_pair

  defp settlement_reply_accounting(_reply), do: :estimated

  defp settlement_result_tags,
    do: [
      :reply_tools_reported,
      :reply_tools_bare,
      :reply_plain_reported,
      :reply_plain_bare,
      :failed,
      :unreadable
    ]

  defp settlement_accounting_tags, do: [:none, :reported_pair, :reported_other, :estimated]

  defp settlement_record(attempt, transport, termination, result_tag, conversation, next, tag) do
    %{
      "run_id" => "run_" <> String.duplicate("r", 30),
      "turn_id" => "turn_" <> String.duplicate("t", 30),
      "operation_id" => "model-operation_" <> String.duplicate("o", 23),
      "attempt" => attempt,
      "staged_request_digest" => String.duplicate("d", 64),
      "transport" => transport,
      "termination" => termination,
      "conversation" => conversation,
      "next" => next,
      "result" => settlement_result(result_tag),
      "accounting" => settlement_accounting(tag),
      "kind" => "model_attempt_settled_v1"
    }
  end

  defp settlement_result(:failed), do: %{"kind" => "error", "category" => "model_call_failed"}

  defp settlement_result(:unreadable),
    do: %{"kind" => "error", "category" => "unreadable_model_answer"}

  defp settlement_result(tag) do
    calls =
      if tag in [:reply_tools_reported, :reply_tools_bare],
        do: [%{"id" => "call-1", "name" => "tool", "arguments" => %{}}],
        else: []

    usage =
      if tag in [:reply_tools_reported, :reply_plain_reported],
        do: %{"status" => "reported", "input_tokens" => 3, "output_tokens" => 2},
        else: %{"status" => "unreported", "category" => "missing"}

    %{
      "kind" => "reply",
      "reply" => %{
        "text" => "answer",
        "identity" => %{
          "provider" => "scripted",
          "model" => "scripted:v1",
          "endpoint" => "in-process"
        },
        "usage" => usage,
        "tool_calls" => calls,
        "delta_count" => 0,
        "streamed" => false,
        "provider_response_id" => nil,
        "staged_request_digest" => String.duplicate("d", 64)
      }
    }
  end

  defp settlement_accounting(:none), do: %{"source" => "none", "basis" => "not_dispatched"}

  defp settlement_accounting(:estimated),
    do: %{"source" => "estimated", "basis" => "remaining_allowance"}

  defp settlement_accounting(:reported_pair),
    do: %{"source" => "reported", "input_tokens" => 3, "output_tokens" => 2}

  defp settlement_accounting(:reported_other),
    do: %{"source" => "reported", "input_tokens" => 9, "output_tokens" => 9}

  defp adapter_reply(request, calls) do
    %{
      "text" => "",
      "identity" => %{
        "provider" => "scripted",
        "model" => "scripted:v1",
        "endpoint" => "in-process"
      },
      "usage" => %{"input_tokens" => 3, "output_tokens" => 2},
      "tool_calls" => calls,
      "delta_count" => 0,
      "streamed" => false,
      "provider_response_id" => nil,
      "staged_request_digest" => request.staged_request_digest,
      "canonical_request_bytes" => request.canonical_request_bytes
    }
  end

  defp canonical_reply(options) do
    calls = Keyword.get(options, :tool_calls, [])

    %{
      "text" => Keyword.get(options, :text, ""),
      "identity" => %{
        "provider" => "scripted",
        "model" => "scripted:v1",
        "endpoint" => "in-process"
      },
      "usage" => %{
        "status" => "reported",
        "input_tokens" => 3,
        "output_tokens" => 2
      },
      "tool_calls" => calls,
      "delta_count" => 0,
      "streamed" => false,
      "provider_response_id" => nil,
      "staged_request_digest" => String.duplicate("d", 64)
    }
  end

  defp settlement_candidate(reply) do
    calls = Map.fetch!(reply, "tool_calls")

    %{
      "kind" => "model_attempt_settled_v1",
      "run_id" => "run_" <> String.duplicate("r", 30),
      "turn_id" => "turn_" <> String.duplicate("t", 30),
      "operation_id" => "model-operation_" <> String.duplicate("o", 23),
      "attempt" => 1,
      "staged_request_digest" => String.duplicate("d", 64),
      "transport" => "dispatched_or_unknown",
      "termination" => nil,
      "conversation" => "canonical",
      "next" => if(calls == [], do: "terminal", else: "continue"),
      "result" => %{"kind" => "reply", "reply" => reply},
      "accounting" => %{
        "source" => "reported",
        "input_tokens" => 3,
        "output_tokens" => 2
      }
    }
  end

  defp text_for_settlement_bytes(target) do
    fixed_bytes = canonical_reply(text: "") |> settlement_candidate() |> record_bytes()

    text = String.duplicate("x", target - fixed_bytes)

    assert record_bytes(canonical_reply(text: text) |> settlement_candidate()) == target

    text
  end

  defp run_reply_preflight(options) do
    calls = Keyword.get(options, :tool_calls, [])

    fixture =
      start(
        script: [
          %{
            text: Keyword.get(options, :text, ""),
            calls: calls,
            usage: %{input_tokens: 3, output_tokens: 2}
          },
          %{text: "finished after admitted tool call", calls: []}
        ],
        tools: if(calls == [], do: [], else: [Fixture.tool_definition()]),
        bounds_token_budget: 1_000_000
      )

    {session_id, _attachment, {:accepted, "prompt-1"}} =
      Fixture.run(fixture, "preflight the provider reply")

    assert %{payload: settlement} =
             await_record(fixture, session_id, fn record ->
               record_kind(record.payload) == "model_attempt_settled_v1"
             end)

    settlement
  end

  defp assert_structural_preflight_boundary(kind) do
    [below, at, above] = structural_boundary_values(kind)

    for {position, value} <- Enum.zip([:below, :at, :above], [below, at, above]) do
      arguments = structural_arguments(kind, value)

      call = %{
        "id" => "preflight-#{kind}-#{position}",
        "name" => "write",
        "arguments" => arguments
      }

      candidate = canonical_reply(tool_calls: [call]) |> settlement_candidate()

      case position do
        admitted when admitted in [:below, :at] ->
          assert :ok = Store.validate_private_record(candidate)

        :above ->
          assert {:error, _structure_exceeded} = Store.validate_private_record(candidate)
      end

      settlement = run_reply_preflight(tool_calls: [call])

      if position in [:below, :at] do
        assert settlement["result"]["kind"] == "reply"
        assert settlement["result"]["reply"]["tool_calls"] == [call]
      else
        assert settlement["result"] == %{
                 "kind" => "error",
                 "category" => "unreadable_model_answer"
               }
      end
    end
  end

  defp structural_boundary_values(:cardinality),
    do: [@record_cardinality_limit - 1, @record_cardinality_limit, @record_cardinality_limit + 1]

  # ADR 0018: the structural limits apply to the whole settlement, whose result projection
  # puts tool-call arguments six nodes below the record root.
  defp structural_boundary_values(:depth) do
    [@record_depth_limit - 7, @record_depth_limit - 6, @record_depth_limit - 5]
  end

  defp structural_arguments(:depth, 0), do: %{"path" => "x", "nested" => "leaf"}

  defp structural_arguments(:depth, depth) do
    %{
      "path" => "x",
      "nested" => Enum.reduce(1..depth, "leaf", fn _, value -> %{"next" => value} end)
    }
  end

  defp structural_arguments(:cardinality, count) do
    extras =
      case count - 1 do
        0 -> %{}
        extra_count -> Map.new(1..extra_count, &{"k#{&1}", &1})
      end

    Map.put(extras, "path", "x")
  end

  defp consecutive_page_kinds(pages, first_kind) do
    kinds =
      Enum.flat_map(pages, fn {_after_version, rows} ->
        Enum.map(rows, &record_kind(&1.payload))
      end)

    case Enum.find_index(kinds, &(&1 == first_kind)) do
      nil -> []
      index -> Enum.slice(kinds, index, 2)
    end
  end

  defp events_before_receipt(events, %{event_sequences: nil}), do: events

  defp events_before_receipt(events, %{event_sequences: %{first: first}}) do
    Enum.filter(events, &(&1.event_sequence < first))
  end

  defp public_event_kind(event) do
    case Map.get(event, :kind) || Map.get(event, "kind") do
      kind when is_atom(kind) -> Atom.to_string(kind)
      kind -> kind
    end
  end

  defp assistant_element?(element) do
    Map.get(element, :kind) in [:assistant_message, :assistant_tool_calls]
  end

  # ADR 0018: the 65,536-byte ceiling applies to the Store's own normalized item, whose
  # `kind` stays an atom key, so a binary-key rewrite overstates every record by three bytes.
  defp record_bytes(record) do
    assert {:ok, _normalized, bytes} = normalize(record)
    bytes
  end

  defp normalize(item), do: apply(Store, :normalize_and_measure_item, [:record, item])

  defp record_kind(record), do: Map.get(record, :kind) || Map.get(record, "kind")

  defp records_of_kind(records, kind),
    do: records |> Enum.map(& &1.payload) |> Enum.filter(&(record_kind(&1) == kind))

  defp add_payload_key(records, kind) do
    {mutated, changed?} =
      Enum.map_reduce(records, false, fn record, changed? ->
        if not changed? and record_kind(record.payload) == kind do
          {%{record | payload: Map.put(record.payload, "unexpected_provider_key", true)}, true}
        else
          {record, changed?}
        end
      end)

    assert changed?
    mutated
  end

  defp assert_exact_settlement_schema(settlement) do
    assert_exact_keys(settlement, [
      "kind",
      "run_id",
      "turn_id",
      "operation_id",
      "attempt",
      "staged_request_digest",
      "transport",
      "termination",
      "conversation",
      "next",
      "result",
      "accounting"
    ])

    case settlement["result"] do
      %{"kind" => "error"} = result ->
        assert_exact_keys(result, ["kind", "category"])

      %{"kind" => "reply", "reply" => reply} = result ->
        assert_exact_keys(result, ["kind", "reply"])

        assert_exact_keys(reply, [
          "text",
          "identity",
          "usage",
          "tool_calls",
          "delta_count",
          "streamed",
          "provider_response_id",
          "staged_request_digest"
        ])

        assert_exact_keys(reply["identity"], ["provider", "model", "endpoint"])

        case reply["usage"] do
          %{"status" => "reported"} = usage ->
            assert_exact_keys(usage, ["status", "input_tokens", "output_tokens"])

          %{"status" => "unreported"} = usage ->
            assert_exact_keys(usage, ["status", "category"])
        end

        for call <- reply["tool_calls"] do
          assert_exact_keys(call, ["id", "name", "arguments"])
        end
    end

    case settlement["accounting"] do
      %{"source" => "none"} = accounting ->
        assert_exact_keys(accounting, ["source", "basis"])

      %{"source" => "reported"} = accounting ->
        assert_exact_keys(accounting, ["source", "input_tokens", "output_tokens"])

      %{"source" => "estimated"} = accounting ->
        assert_exact_keys(accounting, ["source", "basis"])
    end
  end

  defp assert_exact_keys(map, expected) do
    actual =
      map
      |> Map.keys()
      |> Enum.map(fn key -> if is_atom(key), do: Atom.to_string(key), else: key end)
      |> Enum.sort()

    assert actual == Enum.sort(expected)
  end

  defp invalid_attempt_histories(records) do
    first_open =
      Enum.find(records, fn record -> record_kind(record.payload) == "model_attempt_opened_v1" end)

    first_run_id = first_open.payload["run_id"]

    attempt_zero = rewrite_attempt_positions(records, first_run_id, %{1 => 0, 2 => 1})
    attempt_three = rewrite_attempt_positions(records, first_run_id, %{1 => 3, 2 => 4})

    # ADR 0018: attempt two without an exact attempt-one settlement is invalid history, and
    # `Enum.map_reduce/3` returns `{mapped, acc}` so the mapped history is the first element.
    {without_proof, _removed} =
      Enum.map_reduce(records, false, fn record, removed ->
        payload = record.payload

        if not removed and record_kind(payload) == "model_attempt_settled_v1" and
             payload["run_id"] == first_run_id and payload["attempt"] == 1 do
          {nil, true}
        else
          {record, removed}
        end
      end)

    without_proof =
      without_proof
      |> Enum.reject(&is_nil/1)
      |> Enum.with_index(1)
      |> Enum.map(fn {record, journal_version} ->
        %{record | journal_version: journal_version}
      end)

    [
      {"attempt zero", attempt_zero},
      {"attempt above two", attempt_three},
      {"attempt two without exact attempt-one settlement", without_proof}
    ]
  end

  # Concept: the exact history a settlement that retried at the limit would have
  # left, and nothing else.
  #
  # Technical depth: the attempt-two settlement of a twice-refused operation is
  # already `not_dispatched` with no conversation and no accounting, so `next` is
  # the only member that separates the run's truthful terminal from the retry
  # ADR 0018 forbids. Its paired terminal row is dropped with it, because a
  # retry settlement is a one-record transaction: leaving that row behind would
  # make the history refusable for its shape rather than for the cell under test.
  defp spent_attempt_bindings(control) do
    control |> :sys.get_state() |> Map.fetch!(:spent_attempts) |> Map.keys()
  end

  # The abort is in the coordinator's mailbox once it is queued behind the commit
  # the coordinator is blocked in. Polling the queue is what makes the ordering a
  # fact rather than a sleep that a loaded machine can invalidate.
  defp await_queued_command(coordinator, attempts \\ 1_000)
  defp await_queued_command(_coordinator, 0), do: false

  defp await_queued_command(coordinator, attempts) do
    case Process.info(coordinator, :message_queue_len) do
      {:message_queue_len, length} when length > 0 ->
        true

      _empty ->
        Process.sleep(5)
        await_queued_command(coordinator, attempts - 1)
    end
  end

  defp retry_at_the_attempt_limit(records) do
    limit_index = record_index(records, "model_attempt_settled_v1", &(&1["attempt"] == 2))

    records
    |> Enum.take(limit_index + 1)
    |> rewrite_settlement(&(&1["attempt"] == 2), fn payload ->
      Map.put(payload, "next", "retry")
    end)
  end

  defp rewrite_settlement(records, select, rewrite) do
    {mutated, changed?} =
      Enum.map_reduce(records, false, fn record, changed? ->
        payload = record.payload

        if not changed? and record_kind(payload) == "model_attempt_settled_v1" and
             select.(payload) do
          {%{record | payload: rewrite.(payload)}, true}
        else
          {record, changed?}
        end
      end)

    assert changed?
    mutated
  end

  defp rewrite_attempt_positions(records, run_id, replacements) do
    Enum.map(records, fn record ->
      payload = record.payload

      if record_kind(payload) in ["model_attempt_opened_v1", "model_attempt_settled_v1"] and
           payload["run_id"] == run_id and Map.has_key?(replacements, payload["attempt"]) do
        %{
          record
          | payload: Map.put(payload, "attempt", Map.fetch!(replacements, payload["attempt"]))
        }
      else
        record
      end
    end)
  end

  defp assert_unreported_usage(raw_usage, category) do
    token_budget = 11

    fixture =
      start(
        script: [
          %{
            text: "use one tool",
            calls: [
              %{"id" => "usage-c1", "name" => "write", "arguments" => %{"path" => "x"}}
            ],
            usage: %{input_tokens: 3, output_tokens: 2}
          },
          %{text: "finish", calls: [], usage: raw_usage}
        ],
        bounds_token_budget: token_budget
      )

    {session_id, attachment, {:accepted, "prompt-1"}} =
      Fixture.run(fixture, "normalize usage")

    finished = await_event(attachment, "run.finished")
    assert finished["outcome"] == "completed"
    refute finished["outcome"] == "bound_reached"
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 2

    settlements =
      fixture
      |> Fixture.records(session_id)
      |> records_of_kind("model_attempt_settled_v1")

    assert [reported, estimated] = settlements

    assert reported["accounting"] == %{
             "source" => "reported",
             "input_tokens" => 3,
             "output_tokens" => 2
           }

    assert estimated["accounting"] == %{
             "source" => "estimated",
             "basis" => "remaining_allowance"
           }

    assert estimated["result"]["kind"] == "reply"

    assert estimated["result"]["reply"]["usage"] == %{
             "status" => "unreported",
             "category" => category
           }

    assert_remaining_allowance(fixture, session_id, token_budget)
  end

  defp assert_remaining_allowance(fixture, session_id, token_budget) do
    records = Fixture.records(fixture, session_id)

    assert {:ok, recovered} =
             SessionState.recover(session_id, records, Fixture.events(fixture, session_id))

    [settlement | _rest] = records_of_kind(Enum.reverse(records), "model_attempt_settled_v1")
    run_id = settlement["run_id"]
    {declared, charged} = SessionState.accounting(recovered, run_id)

    assert declared.token_budget == token_budget
    assert charged.tokens == token_budget
    assert charged.source == :estimated
  end

  defp traced_transactions(store, acc \\ []) do
    receive do
      {:trace, ^store, :receive, {:"$gen_call", _from, {:transact, transaction}}} ->
        traced_transactions(store, [transaction | acc])

      _other ->
        traced_transactions(store, acc)
    after
      50 ->
        :erlang.trace(store, false, [:all])
        Enum.reverse(acc)
    end
  end

  defp assert_abort_first_ordering do
    fixture =
      start(
        script: [
          %{
            text: "late reply",
            calls: [],
            usage: %{input_tokens: 7, output_tokens: 5},
            hold: self(),
            hold_timeout_ms: 30_000
          }
        ],
        bounds_token_budget: 100
      )

    {session_id, attachment, {:accepted, "prompt-1"}} = Fixture.run(fixture, "abort first")
    assert_receive {:holding, worker}, 5_000

    assert {:accepted, "abort-first"} =
             Loopex.command(attachment, %{type: :abort, command_id: "abort-first"})

    assert await_record(fixture, session_id, fn record ->
             record_kind(record.payload) == "command_admitted" and
               record.payload["command_type"] == "abort" and
               record.payload["admission"] == "accepted"
           end)

    send(worker, :release)
    assert await_event(attachment, "run.finished")["outcome"] == "cancelled"

    records = Fixture.records(fixture, session_id)
    abort_index = record_index(records, "command_admitted", &(&1["command_type"] == "abort"))
    settlement_index = record_index(records, "model_attempt_settled_v1", fn _ -> true end)
    terminal_index = record_index(records, "run_terminal_committed", fn _ -> true end)

    assert abort_index < settlement_index
    assert terminal_index == settlement_index + 1

    [settlement] = records_of_kind(records, "model_attempt_settled_v1")
    assert settlement["termination"] == "abort"
    assert settlement["conversation"] == "evidence_only"
    assert settlement["next"] == "terminal"
    assert settlement["result"]["kind"] == "reply"

    assert settlement["accounting"] == %{
             "source" => "reported",
             "input_tokens" => 7,
             "output_tokens" => 5
           }

    refute Enum.any?(Fixture.events(fixture, session_id), fn event ->
             public_event_kind(event) == "assistant.message_appended"
           end)

    assert {:ok, recovered} =
             SessionState.recover(session_id, records, Fixture.events(fixture, session_id))

    refute Enum.any?(SessionState.elements(recovered, settlement["run_id"]), fn element ->
             assistant_element?(element) and Map.get(element, :content) == "late reply"
           end)
  end

  defp assert_deadline_first_ordering do
    fixture =
      start(
        script: [
          %{
            text: "late reply",
            calls: [],
            usage: %{input_tokens: 7, output_tokens: 5},
            hold: self(),
            hold_timeout_ms: 30_000
          }
        ],
        bounds_token_budget: 100,
        bounds_deadline_ms: 200
      )

    {session_id, attachment, {:accepted, "prompt-1"}} = Fixture.run(fixture, "deadline first")
    assert_receive {:holding, worker}, 5_000

    assert await_record(fixture, session_id, fn record ->
             record_kind(record.payload) == "model_termination_admitted_v1" and
               record.payload["cause"] == "deadline"
           end)

    send(worker, :release)
    finished = await_event(attachment, "run.finished")
    assert finished["outcome"] == "bound_reached"
    assert finished["bound"] == "deadline"

    records = Fixture.records(fixture, session_id)
    deadline_index = record_index(records, "model_termination_admitted_v1", fn _ -> true end)
    settlement_index = record_index(records, "model_attempt_settled_v1", fn _ -> true end)
    terminal_index = record_index(records, "run_terminal_committed", fn _ -> true end)

    assert deadline_index < settlement_index
    assert terminal_index == settlement_index + 1

    [settlement] = records_of_kind(records, "model_attempt_settled_v1")
    assert settlement["termination"] == "deadline"
    assert settlement["conversation"] == "evidence_only"
    assert settlement["next"] == "terminal"
    assert settlement["result"]["kind"] == "reply"

    assert settlement["accounting"] == %{
             "source" => "reported",
             "input_tokens" => 7,
             "output_tokens" => 5
           }

    [termination] = records_of_kind(records, "model_termination_admitted_v1")

    assert_exact_keys(termination, [
      "kind",
      "run_id",
      "turn_id",
      "operation_id",
      "attempt",
      "staged_request_digest",
      "cause",
      "deadline",
      "observed"
    ])

    refute Enum.any?(Fixture.events(fixture, session_id), fn event ->
             public_event_kind(event) == "assistant.message_appended"
           end)

    assert {:ok, recovered} =
             SessionState.recover(session_id, records, Fixture.events(fixture, session_id))

    refute Enum.any?(SessionState.elements(recovered, settlement["run_id"]), fn element ->
             assistant_element?(element) and Map.get(element, :content) == "late reply"
           end)
  end

  defp assert_late_error_ordering do
    fixture =
      start(
        script: [
          %{
            raw_result: {:error, {:provider_credential, "late-private-reason"}},
            hold: self(),
            hold_timeout_ms: 30_000
          }
        ],
        bounds_token_budget: 19
      )

    {session_id, attachment, {:accepted, "prompt-1"}} = Fixture.run(fixture, "late error")
    assert_receive {:holding, worker}, 5_000

    assert {:accepted, "abort-late-error"} =
             Loopex.command(attachment, %{type: :abort, command_id: "abort-late-error"})

    assert await_record(fixture, session_id, fn record ->
             record_kind(record.payload) == "command_admitted" and
               record.payload["command_type"] == "abort" and
               record.payload["admission"] == "accepted"
           end)

    send(worker, :release)
    assert await_event(attachment, "run.finished")["outcome"] == "cancelled"

    records = Fixture.records(fixture, session_id)
    [settlement] = records_of_kind(records, "model_attempt_settled_v1")
    assert settlement["termination"] == "abort"
    assert settlement["conversation"] == "none"
    assert settlement["next"] == "terminal"
    assert settlement["result"] == %{"kind" => "error", "category" => "model_call_failed"}

    assert settlement["accounting"] == %{
             "source" => "estimated",
             "basis" => "remaining_allowance"
           }

    refute Enum.any?(Fixture.events(fixture, session_id), fn event ->
             public_event_kind(event) == "assistant.message_appended"
           end)

    assert_remaining_allowance(fixture, session_id, 19)
  end

  defp await_record(fixture, session_id, predicate, attempts \\ 1_000)
  defp await_record(_fixture, _session_id, _predicate, 0), do: false

  defp await_record(fixture, session_id, predicate, attempts) do
    case Enum.find(Fixture.records(fixture, session_id), predicate) do
      nil ->
        Process.sleep(5)
        await_record(fixture, session_id, predicate, attempts - 1)

      record ->
        record
    end
  end

  defp record_index(records, kind, predicate) do
    Enum.find_index(records, fn record ->
      record_kind(record.payload) == kind and predicate.(record.payload)
    end) || flunk("missing #{kind}")
  end

  defp attempt_identity(opened) do
    Map.take(opened, ["run_id", "turn_id", "operation_id", "attempt", "staged_request_digest"])
  end

  defp permit_authority!(fixture, session_id, opened, request, worker) do
    coordinator = coordinator_of(fixture.runtime)
    state = :sys.get_state(coordinator)

    stamped_open =
      fixture
      |> Fixture.records(session_id)
      |> Enum.find(fn record ->
        record_kind(record.payload) == "model_attempt_opened_v1" and
          attempt_identity(record.payload) == attempt_identity(opened)
      end) || flunk("the committed attempt-open row was not retained")

    deadline =
      fixture
      |> Fixture.records(session_id)
      |> Enum.find(&(record_kind(&1.payload) == "model_request_committed"))
      |> then(fn
        nil -> flunk("the committed request row was not retained")
        record -> committed_deadline!(record.payload)
      end)

    authority = %{
      runtime_id: fixture.runtime_id,
      session_id: session_id,
      owner_epoch: state.owner.owner_epoch,
      owner_incarnation_id: state.owner.owner_incarnation_id,
      coordinator: coordinator,
      journal_version: stamped_open.journal_version,
      worker: worker,
      deadline: deadline
    }

    for {_field, value} <- authority do
      assert contains_exact?(request, value),
             "provider-permit request omitted an independently observed authority member"
    end

    authority
  end

  defp await_control_request_binding(control, worker, expected, attempts \\ 1_000)

  defp await_control_request_binding(_control, _worker, _expected, 0),
    do:
      flunk("Control never received a provider permit request carrying the full attempt binding")

  defp await_control_request_binding(control, worker, expected, attempts) do
    receive do
      {:trace, ^control, :receive, {:"$gen_call", {caller, _tag}, request}} ->
        if contains_exact?(request, worker) and coherent_attempt_bindings(request, expected) != [] do
          {caller, request}
        else
          await_control_request_binding(control, worker, expected, attempts - 1)
        end

      _other ->
        await_control_request_binding(control, worker, expected, attempts - 1)
    after
      5 -> await_control_request_binding(control, worker, expected, attempts - 1)
    end
  end

  defp coherent_attempt_binding!(term, expected) do
    case coherent_attempt_bindings(term, expected) do
      [binding] -> binding
      [] -> flunk("no single map carries the exact full provider-attempt binding")
      bindings -> flunk("provider permit carries #{length(bindings)} competing attempt bindings")
    end
  end

  defp coherent_attempt_binding_container!(term, expected) do
    expected_keys = Map.keys(expected) |> Enum.sort()

    containers =
      term
      |> maps()
      |> Enum.filter(fn map ->
        normalized =
          Map.new(map, fn {key, value} ->
            normalized_key = if is_atom(key) or is_binary(key), do: to_string(key), else: key
            {normalized_key, value}
          end)

        Map.take(normalized, expected_keys) == expected
      end)
      |> Enum.uniq()

    case containers do
      [container] -> container
      [] -> flunk("no map contains the exact full provider-attempt binding")
      many -> flunk("provider permit carries #{length(many)} competing binding containers")
    end
  end

  defp coherent_attempt_bindings(term, expected) do
    expected_keys = Map.keys(expected) |> Enum.sort()

    term
    |> maps()
    |> Enum.map(fn map ->
      Map.new(map, fn {key, value} ->
        normalized_key = if is_atom(key) or is_binary(key), do: to_string(key), else: key
        {normalized_key, value}
      end)
    end)
    |> Enum.filter(fn map -> Map.take(map, expected_keys) == expected end)
    |> Enum.map(&Map.take(&1, expected_keys))
    |> Enum.uniq()
  end

  defp maps(term) when is_map(term),
    do: [term | Enum.flat_map(term, fn {key, value} -> maps(key) ++ maps(value) end)]

  defp maps(term) when is_tuple(term), do: term |> Tuple.to_list() |> Enum.flat_map(&maps/1)
  defp maps(term) when is_list(term), do: Enum.flat_map(term, &maps/1)
  defp maps(_term), do: []

  defp references(term) when is_reference(term), do: MapSet.new([term])

  defp references(term) when is_map(term),
    do:
      Enum.reduce(term, MapSet.new(), fn {key, value}, refs ->
        refs |> MapSet.union(references(key)) |> MapSet.union(references(value))
      end)

  defp references(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> references()

  defp references(term) when is_list(term),
    do: Enum.reduce(term, MapSet.new(), &MapSet.union(references(&1), &2))

  defp references(_term), do: MapSet.new()

  defp contains_exact?(term, expected) when term === expected, do: true

  defp contains_exact?(term, expected) when is_map(term),
    do: Enum.any?(term, &contains_exact?(&1, expected))

  defp contains_exact?(term, expected) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.any?(&contains_exact?(&1, expected))

  defp contains_exact?(term, expected) when is_list(term),
    do: Enum.any?(term, &contains_exact?(&1, expected))

  defp contains_exact?(_term, _expected), do: false

  defp replace_exact(term, from, to) when term === from, do: to

  defp replace_exact(term, from, to) when is_map(term) do
    Map.new(term, fn {key, value} ->
      {replace_exact(key, from, to), replace_exact(value, from, to)}
    end)
  end

  defp replace_exact(term, from, to) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> Enum.map(&replace_exact(&1, from, to))
    |> List.to_tuple()
  end

  defp replace_exact(term, from, to) when is_list(term),
    do: Enum.map(term, &replace_exact(&1, from, to))

  defp replace_exact(term, _from, _to), do: term

  defp coordinator_of(runtime) do
    {:ok, %{sessions: sessions}} = Runtime.children(runtime)

    sessions
    |> DynamicSupervisor.which_children()
    |> Enum.find_value(fn
      {_id, pid, :worker, _modules} when is_pid(pid) -> pid
      _other -> nil
    end)
  end

  defp await_event(attachment, kind, attempts \\ 1_000)
  defp await_event(_attachment, kind, 0), do: flunk("never observed #{kind}")

  defp await_event(attachment, kind, attempts) do
    case Loopex.next_event(attachment) do
      {:ok, %{kind: ^kind} = event} ->
        event

      {:ok, _other} ->
        await_event(attachment, kind, attempts - 1)

      _other ->
        Process.sleep(5)
        await_event(attachment, kind, attempts - 1)
    end
  end

  defp await_events_through(attachment, kind, acc \\ [], attempts \\ 1_000)

  defp await_events_through(_attachment, kind, _acc, 0),
    do: flunk("never observed #{kind}")

  defp await_events_through(attachment, kind, acc, attempts) do
    case Loopex.next_event(attachment) do
      {:ok, %{kind: ^kind} = event} ->
        Enum.reverse([event | acc])

      {:ok, event} ->
        await_events_through(attachment, kind, [event | acc], attempts - 1)

      _other ->
        Process.sleep(5)
        await_events_through(attachment, kind, acc, attempts - 1)
    end
  end

  defp available_events(attachment, acc \\ []) do
    case Loopex.next_event(attachment) do
      {:ok, event} -> available_events(attachment, [event | acc])
      _other -> Enum.reverse(acc)
    end
  end

  defp receive_progress(acc \\ []) do
    receive do
      {:loopex_progress, item} -> receive_progress([item | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  defp receive_diagnostics(acc \\ []) do
    receive do
      {:loopex_diagnostic, item} -> receive_diagnostics([item | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  defp printable(value) do
    inspect(value,
      limit: :infinity,
      printable_limit: :infinity,
      charlists: :as_lists
    )
  end
end
