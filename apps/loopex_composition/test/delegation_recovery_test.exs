Code.require_file("support/delegation_runtime_fixture.exs", __DIR__)

defmodule LoopexComposition.DelegationRecoveryTest do
  use ExUnit.Case, async: false

  alias LoopexComposition.Delegation.{Helper, RunLedger}
  alias LoopexComposition.DelegationRuntimeFixture, as: Fixture
  alias LoopexComposition.HelperDeciderModel

  # Concept: each case freezes the host at one durable helper boundary, loses
  # every process, restarts over the same root and classifies before admission.
  # Technical depth: recovery is stop-only: no case may create a second child or
  # submit a second child prompt, and every parent ends with a known receipt or
  # an honest unknown with its helper slot still occupied.
  @cases [
    {:before_reserve, :failed, 0},
    {:after_reserve, :unresolved, 0},
    {:after_create, :failed, 0},
    {:before_settle, :completed, 1},
    {:after_settle, :completed, 1}
  ]

  for {step, expected, child_requests} <- @cases do
    @step step
    @expected expected
    @child_requests child_requests
    test "loss at #{step} recovers stop-only to #{expected}" do
      test = self()
      fixture = Fixture.start(decide(), fault: fault(test, @step))
      parent = Fixture.parent(fixture, "parent-create")
      {_attachment, run} = Fixture.prompt(fixture, parent, "parent-prompt", "parent:x")
      assert_receive {:fault, @step}, 10_000
      restarted = Fixture.restart(fixture)
      status = Helper.status(restarted.helper)
      assert status.classified == :complete
      assert map_size(status.children) <= 1
      child_count = map_size(status.children)

      ledger = status.runs[{parent, run}]

      case @expected do
        :unresolved ->
          assert RunLedger.occupied?(ledger)
          assert status.receipts == %{}

        outcome ->
          assert [{_job, receipt}] = Map.to_list(status.receipts)
          assert receipt.outcome == outcome
          refute RunLedger.occupied?(ledger)
          assert ledger.count == 1
      end

      if @step == :after_create do
        # Concept: the unprompted child's terminal names its actual last record.
        [settle] =
          for {tx, _} <- ledger.transactions, tx["mutation"]["kind"] == "settle", do: tx

        terminal = settle["mutation"]["terminal"]
        child = Base.decode64!(terminal["child_session_id"])
        through = terminal["journal_version"]
        {:ok, [last]} = Loopex.Store.load_records(restarted.store, child, through - 1, 1)
        assert last.journal_version == through

        assert terminal["terminal_record_sha256"] ==
                 LoopexProtocol.Canonical.digest(last.payload)
      end

      assert {:ok, {:prepared, activation}} =
               Loopex.prepare_resume_session(restarted.runtime, parent, "resume-parent")

      assert {:ok, _} = Loopex.activate_resume(activation)
      evidence = Fixture.await_terminal(restarted, parent, run)

      if @expected == :unresolved,
        do: assert(evidence.terminal.state == "outcome_unknown"),
        else: assert(evidence.terminal.state == "completed")

      child_prompts =
        restarted.model
        |> HelperDeciderModel.dispatched()
        |> Enum.count(fn request ->
          Enum.any?(request.messages, &(&1["role"] == "user" and &1["content"] == "child:x"))
        end)

      assert child_prompts == @child_requests
      assert map_size(Helper.status(restarted.helper).children) == child_count
    end
  end

  # Concept: a missing prompt acknowledgement alone never proves "unprompted".
  # Technical depth: ADR 0056. The helper is lost right after creating its
  # child. Before the restarted owner classifies, trusted host code holds a
  # live, activated child owner under the recovery's former fixed resume
  # identity, so a repeated presentation would only replay and leave that owner
  # live. Recovery must instead take ownership afresh (one new
  # `owner_advanced` record) before it reads the absent admission, and only
  # then settle the failed terminal at zero exactly once.
  test "an unprompted verdict comes only from a fresh prepared child owner" do
    test = self()
    fixture = Fixture.start(decide(), fault: fault(test, :after_create))
    parent = Fixture.parent(fixture, "parent-create")
    {_attachment, run} = Fixture.prompt(fixture, parent, "parent-prompt", "parent:x")
    assert_receive {:fault, :after_create}, 10_000
    restarted = Fixture.restart(fixture, classify: :skip)

    {:ok, {:page, %{rows: rows, next_cursor: nil}}} =
      Loopex.Runtime.creation_provenance(restarted.runtime, %{
        kind: :runtime_page,
        cursor: nil,
        limit: 16
      })

    [row] = for row <- rows, row.session_id != parent, do: row
    child = row.session_id

    assert {:ok, {:prepared, activation}} =
             Loopex.prepare_resume_session(
               restarted.runtime,
               child,
               "helper-recovery:" <> row.command_id
             )

    assert {:ok, ^child} = Loopex.activate_resume(activation)
    advanced = owner_advances(restarted, child)
    assert Helper.classify(restarted.helper) == :ok
    assert owner_advances(restarted, child) == advanced + 1

    status = Helper.status(restarted.helper)
    ledger = status.runs[{parent, run}]
    refute RunLedger.occupied?(ledger)
    assert [{_job, %{outcome: :failed}}] = Map.to_list(status.receipts)

    assert [%{"charge_tokens" => 0, "terminal" => %{"child_run_id" => nil}}] =
             for(
               {tx, _} <- ledger.transactions,
               tx["mutation"]["kind"] == "settle",
               do: tx["mutation"]
             )
  end

  defp owner_advances(fixture, session) do
    {:ok, rows} = Loopex.Store.load_records(fixture.store, session, 0, 1_000)
    Enum.count(rows, &(&1.payload.kind == "owner_advanced"))
  end

  test "a prompted child interrupted mid-flight is stopped, never prompted again" do
    test = self()

    decide = fn
      "parent:" <> _, 0 -> %{text: "go", calls: [Fixture.task_call("t-1", "inspect", "child:x")]}
      "child:" <> _, 0 -> %{text: "late", calls: [], hold: test, hold_timeout_ms: 60_000}
      _user, _turns -> %{text: "done", calls: []}
    end

    fixture = Fixture.start(decide)
    parent = Fixture.parent(fixture, "parent-create")
    {_attachment, run} = Fixture.prompt(fixture, parent, "parent-prompt", "parent:x")
    assert_receive {:holding, "child:x", _worker}, 10_000
    restarted = Fixture.restart(fixture)
    status = Helper.status(restarted.helper)
    assert status.classified == :complete
    assert [{child, _}] = Map.to_list(status.children)
    ledger = status.runs[{parent, run}]

    kinds = for {tx, _} <- ledger.transactions, do: tx["mutation"]["kind"]
    assert "stop" in kinds

    [stop] = for {tx, _} <- ledger.transactions, tx["mutation"]["kind"] == "stop", do: tx
    assert stop["mutation"]["reason"] == "adapter_recovery"

    {:ok, rows} = Loopex.Store.load_records(restarted.store, child, 0, 1_000)

    assert Enum.count(rows, &(&1.payload.kind == "prompt_admitted_v3")) == 1
    refute Enum.any?(rows, &(&1.payload.kind == "session_genesis_v3" and &1.journal_version > 1))

    child_prompts =
      restarted.model
      |> HelperDeciderModel.dispatched()
      |> Enum.count(fn request ->
        Enum.any?(request.messages, &(&1["role"] == "user" and &1["content"] == "child:x"))
      end)

    assert child_prompts == 1
  end

  # V8.6: a serial allowance exhausted in one run survives restart unchanged.
  # The refused call takes no count, tokens or ledger row, and its committed
  # pre-effect refusal leaves the parent activatable for a new run.
  test "an exhausted serial child allowance survives restart and the parent reopens" do
    decide = fn
      "parent:" <> _, turn when turn in 0..2 ->
        %{text: "go", calls: [Fixture.task_call("t-#{turn}", "inspect", "child:#{turn}")]}

      "child:" <> _, _ ->
        %{text: "finding", calls: []}

      _user, _turns ->
        %{text: "done", calls: []}
    end

    fixture = Fixture.start(decide)
    parent = Fixture.parent(fixture, "parent-create", %{"max_children" => 2})
    {_attachment, run} = Fixture.prompt(fixture, parent, "parent-prompt", "parent:x")
    assert Fixture.await_terminal(fixture, parent, run).terminal.state == "completed"
    {:ok, rows} = Loopex.Store.load_records(fixture.store, parent, 0, 1_000)

    refusals =
      for %{payload: %{kind: "tool_result_committed_v2"} = result} <- rows,
          do: {result["tool_call_id"], result["outcome"], result["reason"]}

    assert refusals == [{"t-2", "failed", "delegation_count_exhausted"}]
    before = Helper.status(fixture.helper).runs[{parent, run}]
    assert before.count == 2 and before.reserved_tokens == 0
    assert map_size(Helper.status(fixture.helper).children) == 2

    restarted = Fixture.restart(fixture)
    status = Helper.status(restarted.helper)
    assert status.classified == :complete
    after_restart = status.runs[{parent, run}]
    assert after_restart.count == before.count
    assert after_restart.charged_tokens == before.charged_tokens
    assert after_restart.transactions == before.transactions
    assert map_size(status.children) == 2

    assert {:ok, ^parent} =
             Loopex.resume_session(restarted.runtime, parent, command_id: "resume")

    {_attachment, later} = Fixture.prompt(restarted, parent, "later-prompt", "after restart")
    assert Fixture.await_terminal(restarted, parent, later).terminal.state == "completed"
    assert Helper.status(restarted.helper).runs[{parent, run}] == after_restart
  end

  test "a lost bind acknowledgement finishes from exact creation history" do
    test = self()
    fixture = Fixture.start(decide(), fault: fault(test, :after_parent_create))
    capture = Fixture.capture("parent-create")
    Task.start(fn -> Helper.create_parent(fixture.helper, capture) end)
    assert_receive {:fault, :after_parent_create}, 10_000
    restarted = Fixture.restart(fixture)
    status = Helper.status(restarted.helper)
    assert status.classified == :complete
    assert [{parent, _}] = Map.to_list(status.parents)
    assert {:ok, ^parent} = Loopex.resume_session(restarted.runtime, parent, command_id: "resume")
    {_attachment, run} = Fixture.prompt(restarted, parent, "parent-prompt", "parent:x")
    assert Fixture.await_terminal(restarted, parent, run).terminal.state == "completed"
    assert map_size(Helper.status(restarted.helper).receipts) == 1
    # Concept: re-presenting the same creation returns the original parent.
    assert Helper.create_parent(restarted.helper, capture) == {:ok, parent}
  end

  test "a prepared parent never created fences helpers until its creation is re-presented" do
    test = self()
    fixture = Fixture.start(decide(), fault: fault(test, :after_prepare))
    capture = Fixture.capture("parent-create")
    Task.start(fn -> Helper.create_parent(fixture.helper, capture) end)
    assert_receive {:fault, :after_prepare}, 10_000
    restarted = Fixture.restart(fixture)
    assert Helper.status(restarted.helper).parents == %{}
    assert {:ok, parent} = Helper.create_parent(restarted.helper, capture)
    {_attachment, run} = Fixture.prompt(restarted, parent, "parent-prompt", "parent:x")
    assert Fixture.await_terminal(restarted, parent, run).terminal.state == "completed"
    assert map_size(Helper.status(restarted.helper).receipts) == 1
  end

  test "loss right after a committed cancel stop never re-prompts and keeps the first stop" do
    test = self()

    decide = fn
      "parent:" <> _, 0 -> %{text: "go", calls: [Fixture.task_call("t-1", "inspect", "child:x")]}
      "child:" <> _, 0 -> %{text: "late", calls: [], hold: test, hold_timeout_ms: 60_000}
      _user, _turns -> %{text: "done", calls: []}
    end

    fixture = Fixture.start(decide, fault: fault(test, :after_stop))
    parent = Fixture.parent(fixture, "parent-create")
    {attachment, run} = Fixture.prompt(fixture, parent, "parent-prompt", "parent:x")
    assert_receive {:holding, "child:x", _worker}, 10_000

    Task.start(fn ->
      Loopex.command(attachment, %{type: :abort, command_id: "abort", run_id: run})
    end)

    assert_receive {:fault, :after_stop}, 10_000
    restarted = Fixture.restart(fixture)
    ledger = Helper.status(restarted.helper).runs[{parent, run}]
    stops = for {tx, _} <- ledger.transactions, tx["mutation"]["kind"] == "stop", do: tx
    assert [stop] = stops
    assert stop["mutation"]["reason"] == "cancel"

    child_prompts =
      restarted.model
      |> HelperDeciderModel.dispatched()
      |> Enum.count(fn request ->
        Enum.any?(request.messages, &(&1["role"] == "user" and &1["content"] == "child:x"))
      end)

    assert child_prompts == 1
    assert map_size(Helper.status(restarted.helper).children) == 1
  end

  test "sync uncertainty in one parent fences the whole adapter until restart resolves it" do
    synced = :counters.new(1, [])

    checkpoint = fn step ->
      if step == :run_synced do
        :counters.add(synced, 1, 1)
        if :counters.get(synced, 1) == 2, do: {:error, :physical_cut}, else: :ok
      else
        :ok
      end
    end

    fixture =
      Fixture.start(
        [
          %{text: "a", calls: [Fixture.task_call("call-a")]},
          %{text: "b", calls: [Fixture.task_call("call-b")]},
          %{text: "b done", calls: []}
        ],
        checkpoint: checkpoint
      )

    a = Fixture.parent(fixture, "create-a")
    b = Fixture.parent(fixture, "create-b")
    {_attachment, run_a} = Fixture.prompt(fixture, a, "prompt-a", "a")
    assert Fixture.await_terminal(fixture, a, run_a).terminal.state == "outcome_unknown"
    assert Helper.status(fixture.helper).fenced
    {_attachment, run_b} = Fixture.prompt(fixture, b, "prompt-b", "b")
    assert Fixture.await_terminal(fixture, b, run_b).terminal.state == "completed"
    {:ok, rows} = Loopex.Store.load_records(fixture.store, b, 0, 1_000)

    assert [{"call-b", "failed", "ledger_fenced"}] =
             for(
               %{payload: %{kind: "tool_result_committed_v2"} = p} <- rows,
               do: {p["tool_call_id"], p["outcome"], p["reason"]}
             )

    assert Helper.status(fixture.helper).children == %{}
    restarted = Fixture.restart(fixture)
    status = Helper.status(restarted.helper)
    assert status.classified == :complete and not status.fenced
    assert RunLedger.occupied?(status.runs[{a, run_a}])
  end

  defp decide do
    fn
      "parent:" <> _, 0 ->
        %{text: "go", calls: [Fixture.task_call("t-1", "inspect", "child:x")]}

      "child:" <> _, 0 ->
        %{text: "Finding", calls: [], usage: %{input_tokens: 5, output_tokens: 3}}

      _user, _turns ->
        %{text: "done", calls: []}
    end
  end

  defp fault(test, target) do
    fn step ->
      if step == target do
        send(test, {:fault, step})

        receive do
          :never -> :ok
        end
      else
        :ok
      end
    end
  end
end
