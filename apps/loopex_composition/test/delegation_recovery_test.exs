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
