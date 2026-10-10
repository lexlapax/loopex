Code.require_file("support/delegation_runtime_fixture.exs", __DIR__)

defmodule LoopexComposition.DelegationHelperTest do
  use ExUnit.Case, async: false

  alias Loopex.{AgentLoopTestExecutor, AgentLoopTestModel, Runtime}
  alias LoopexComposition.Delegation.{Helper, Router, Tool}
  alias LoopexComposition.DelegationRuntimeFixture, as: Fixture

  test "a parent delegates one read-only child and receives its settled receipt" do
    fixture =
      Fixture.start([
        %{text: "delegating", calls: [Fixture.task_call("call-task")], usage: usage(30, 5)},
        %{
          text: "reading",
          calls: [%{id: "child-read", name: "read", arguments: %{"path" => "README.md"}}],
          usage: usage(40, 6)
        },
        %{text: "Finding: README is present.", calls: [], usage: usage(50, 7)},
        %{text: "Parent done.", calls: [], usage: usage(20, 3)}
      ])

    parent = Fixture.parent(fixture, "parent-create")
    {_attachment, run} = Fixture.prompt(fixture, parent, "parent-prompt", "investigate")
    parent_evidence = Fixture.await_terminal(fixture, parent, run)
    assert parent_evidence.terminal.state == "completed"

    status = Helper.status(fixture.helper)
    assert [{child, _job}] = Map.to_list(status.children)
    assert map_size(status.receipts) == 1
    [{_job_id, receipt}] = Map.to_list(status.receipts)
    assert receipt.outcome == :completed

    assert {:ok, output} =
             LoopexComposition.Delegation.LedgerCodec.decode_json(receipt.output, :object)

    assert output["text"] == "Finding: README is present."
    assert output["child_session_id"] == child
    assert output["usage"]["child"]["reported_input_tokens"] == 90
    assert output["usage"]["child"]["reported_output_tokens"] == 13
    assert output["usage"]["delegation"]["charged_tokens"] == 103

    # Concept: the child ran only read-only tools and the parent the task.
    jobs = AgentLoopTestExecutor.jobs(fixture.executor)
    assert Enum.map(jobs, & &1.tool_id) == ["loopex.read"]
    assert hd(jobs).session_id == child

    [{_key, ledger}] = Map.to_list(status.runs)
    refute LoopexComposition.Delegation.RunLedger.occupied?(ledger)
    assert ledger.count == 1 and ledger.charged_tokens == 103 and ledger.credit == 0
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == 4
    assert {:ok, :helper_child} = Helper.classify_session(fixture.helper, child)
    assert {:ok, :helper_parent} = Helper.classify_session(fixture.helper, parent)
  end

  defmodule DeferReadPolicy do
    @moduledoc false
    @behaviour Loopex.Policy

    @impl Loopex.Policy
    def decide(%{generation: {"loopex.read", _, _}}),
      do:
        {:defer,
         %{
           kind: :choice,
           prompt: "Read?",
           choices: [%{id: "ok", label: "OK"}],
           expires_in_ms: 60_000
         }}

    def decide(_request), do: {:allow, nil}
  end

  test "children cannot nest, widen tools or open questions" do
    fixture =
      Fixture.start(
        [
          %{text: "delegating", calls: [Fixture.task_call("call-task")]},
          %{
            text: "trying",
            calls: [
              Fixture.task_call("nested"),
              %{id: "child-write", name: "write", arguments: %{"path" => "x"}},
              %{id: "child-read", name: "read", arguments: %{"path" => "README.md"}}
            ]
          },
          %{text: "No widening was possible.", calls: []},
          %{text: "Parent done.", calls: []}
        ],
        policy: DeferReadPolicy
      )

    parent = Fixture.parent(fixture, "parent-create")
    {_attachment, run} = Fixture.prompt(fixture, parent, "parent-prompt", "investigate")
    assert Fixture.await_terminal(fixture, parent, run).terminal.state == "completed"
    status = Helper.status(fixture.helper)
    assert [{child, _}] = Map.to_list(status.children)
    assert AgentLoopTestExecutor.jobs(fixture.executor) == []
    {:ok, rows} = Loopex.Store.load_records(fixture.store, child, 0, 1_000)
    kinds = Enum.map(rows, & &1.payload.kind)
    refute "interaction_requested_v1" in kinds
    refute "effect_intent_committed_v2" in kinds

    results =
      for %{payload: %{kind: "tool_result_committed_v2"} = payload} <- rows,
          do: {payload["tool_call_id"], payload["outcome"]}

    assert Enum.sort(results) == [
             {"child-read", "denied"},
             {"child-write", "failed"},
             {"nested", "failed"}
           ]

    [{_job, receipt}] = Map.to_list(status.receipts)
    assert receipt.outcome == :completed
  end

  test "count and token exhaustion refuse before any reservation and a new run reopens" do
    fixture =
      Fixture.start([
        %{text: "first", calls: [Fixture.task_call("call-1")]},
        %{text: "Overshoot finding.", calls: [], usage: usage(1_500, 600)},
        %{text: "second", calls: [Fixture.task_call("call-2")]},
        %{text: "Parent saw exhaustion.", calls: []},
        %{text: "third", calls: [Fixture.task_call("call-3")]},
        %{text: "Second run finding.", calls: []},
        %{text: "Parent done.", calls: []}
      ])

    parent = Fixture.parent(fixture, "parent-create", %{"token_budget" => 2_000})
    {_attachment, run} = Fixture.prompt(fixture, parent, "prompt-1", "investigate")
    assert Fixture.await_terminal(fixture, parent, run).terminal.state == "completed"
    {:ok, rows} = Loopex.Store.load_records(fixture.store, parent, 0, 1_000)

    assert outcomes(rows) == [
             {"call-1", :receipt},
             {"call-2", {"failed", "delegation_tokens_exhausted"}}
           ]

    status = Helper.status(fixture.helper)
    ledger = status.runs[{parent, run}]
    assert ledger.count == 1 and ledger.charged_tokens == 2_100 and ledger.reserved_tokens == 0

    {_attachment, second} = Fixture.prompt(fixture, parent, "prompt-2", "again")
    assert Fixture.await_terminal(fixture, parent, second).terminal.state == "completed"
    second_ledger = Helper.status(fixture.helper).runs[{parent, second}]
    assert second_ledger.count == 1 and second_ledger.charged_tokens == 2
    assert Helper.status(fixture.helper).runs[{parent, run}] == ledger
  end

  test "the child count bounds repeated cheap calls in one run" do
    fixture =
      Fixture.start([
        %{text: "first", calls: [Fixture.task_call("call-1")]},
        %{text: "cheap", calls: []},
        %{text: "second", calls: [Fixture.task_call("call-2")]},
        %{text: "Parent done.", calls: []}
      ])

    parent = Fixture.parent(fixture, "parent-create", %{"max_children" => 1})
    {_attachment, run} = Fixture.prompt(fixture, parent, "prompt-1", "investigate")
    assert Fixture.await_terminal(fixture, parent, run).terminal.state == "completed"
    {:ok, rows} = Loopex.Store.load_records(fixture.store, parent, 0, 1_000)

    assert outcomes(rows) == [
             {"call-1", :receipt},
             {"call-2", {"failed", "delegation_count_exhausted"}}
           ]
  end

  test "an unresolved child keeps its parent's slot occupied across runs" do
    fixture =
      Fixture.start(
        [
          %{text: "first", calls: [Fixture.task_call("call-1")]},
          %{
            text: "reading",
            calls: [%{id: "child-read", name: "read", arguments: %{"path" => "a"}}]
          },
          %{text: "second run", calls: [Fixture.task_call("call-2")]},
          %{text: "Parent done.", calls: []}
        ],
        outcomes: %{"child-read" => "outcome_unknown"}
      )

    parent = Fixture.parent(fixture, "parent-create")
    {_attachment, run} = Fixture.prompt(fixture, parent, "prompt-1", "investigate")
    assert Fixture.await_terminal(fixture, parent, run).terminal.state == "outcome_unknown"
    {_attachment, second} = Fixture.prompt(fixture, parent, "prompt-2", "again")
    assert Fixture.await_terminal(fixture, parent, second).terminal.state == "completed"
    {:ok, rows} = Loopex.Store.load_records(fixture.store, parent, 0, 1_000)
    assert {"call-2", {"failed", "helper_slot_occupied"}} in outcomes(rows)
    status = Helper.status(fixture.helper)
    assert map_size(status.children) == 1 and status.receipts == %{}
    assert LoopexComposition.Delegation.RunLedger.occupied?(status.runs[{parent, run}])
  end

  test "independent parents run overlapping children with separate allowances" do
    test = self()

    decide = fn
      "parent:" <> name, 0 ->
        %{text: "go", calls: [Fixture.task_call("t-" <> name, "inspect", "child:" <> name)]}

      "child:" <> name, 0 ->
        %{text: "Finding " <> name, calls: [], hold: test}

      _user, _turns ->
        %{text: "done", calls: []}
    end

    fixture = Fixture.start(decide)
    a = Fixture.parent(fixture, "create-a")
    b = Fixture.parent(fixture, "create-b")
    {_attachment, run_a} = Fixture.prompt(fixture, a, "prompt-a", "parent:a")
    {_attachment, run_b} = Fixture.prompt(fixture, b, "prompt-b", "parent:b")
    assert_receive {:holding, first, worker_1}, 10_000
    assert_receive {:holding, second, worker_2}, 10_000
    assert Enum.sort([first, second]) == ["child:a", "child:b"]
    assert map_size(Helper.status(fixture.helper).children) == 2
    send(worker_1, :release)
    send(worker_2, :release)
    assert Fixture.await_terminal(fixture, a, run_a).terminal.state == "completed"
    assert Fixture.await_terminal(fixture, b, run_b).terminal.state == "completed"
    status = Helper.status(fixture.helper)
    assert map_size(status.receipts) == 2

    for {session, run} <- [{a, run_a}, {b, run_b}] do
      ledger = status.runs[{session, run}]
      assert ledger.count == 1 and ledger.charged_tokens == 2
      refute LoopexComposition.Delegation.RunLedger.occupied?(ledger)
    end
  end

  test "cancelling the parent stops its child and confirms cleanup" do
    test = self()

    decide = fn
      "parent:" <> _, 0 -> %{text: "go", calls: [Fixture.task_call("t-1", "inspect", "child:x")]}
      "child:" <> _, 0 -> %{text: "late", calls: [], hold: test}
      _user, _turns -> %{text: "done", calls: []}
    end

    fixture = Fixture.start(decide)
    parent = Fixture.parent(fixture, "create")
    {attachment, run} = Fixture.prompt(fixture, parent, "prompt", "parent:x")
    assert_receive {:holding, "child:x", worker}, 10_000

    assert {:accepted, "abort"} =
             Loopex.command(attachment, %{type: :abort, command_id: "abort", run_id: run})

    assert Fixture.await_terminal(fixture, parent, run).terminal.state == "cancelled"
    send(worker, :release)
    status = Helper.status(fixture.helper)
    [{child, _}] = Map.to_list(status.children)
    child_runs = for {_k, ledger} <- status.runs, do: ledger.transactions
    kinds = for transactions <- child_runs, {tx, _} <- transactions, do: tx["mutation"]["kind"]
    assert "stop" in kinds
    {:ok, rows} = Loopex.Store.load_records(fixture.store, child, 0, 1_000)
    [terminal] = for %{payload: %{kind: "run_terminal_committed"} = p} <- rows, do: p["outcome"]
    assert terminal == "cancelled"
  end

  # Concept: the helper route validates the executor grant like a local job.
  # Technical depth: ADR 0046 keeps grant validation unchanged on the helper
  # branch. Each grant below differs from Core's issued grant in exactly one
  # binding or current fact; every one refuses with the standard executor
  # reason before the owner sees the job, so nothing is reserved, no child is
  # created and no model request is made.
  test "the helper route refuses expired, foreign, refenced and wrong-lease grants first" do
    fixture = Fixture.start([%{text: "unused", calls: []}])
    parent = Fixture.parent(fixture, "parent-create")
    router = router(fixture)
    {job, grant} = helper_job(parent)
    before = Helper.status(fixture.helper)
    past = System.system_time(:millisecond) - 1

    cases = [
      {%{grant | expiry: past}, job, {:binding_mismatch, :expiry}},
      {%{grant | executor_audience: "other-executor"}, job,
       {:binding_mismatch, :executor_audience}},
      {%{grant | fencing_token: 2}, job, {:binding_mismatch, :fencing_token}},
      {%{grant | workspace_lease: "other-lease"}, job, {:binding_mismatch, :workspace_lease}},
      {Map.delete(grant, :issued_by), job, :host_policy_allow_required}
    ]

    {foreign, foreign_grant} = helper_job(parent, executor_identity: "other-executor")
    {refenced, refenced_grant} = helper_job(parent, fencing_token: 2)
    {leased, leased_grant} = helper_job(parent, workspace_lease: "other-lease")
    {old_epoch, old_epoch_grant} = helper_job(parent, origin_executor_epoch: 0)

    cases =
      cases ++
        [
          {foreign_grant, foreign, {:binding_mismatch, :executor_audience}},
          {refenced_grant, refenced, {:binding_mismatch, :fencing_token}},
          {leased_grant, leased, {:binding_mismatch, :workspace_lease}},
          {old_epoch_grant, old_epoch, :executor_prestart_mismatch}
        ]

    for {grant, job, reason} <- cases do
      assert Router.execute(router, job, grant, [], nil) ==
               {:error, {:refused_before_effect, reason}}
    end

    after_status = Helper.status(fixture.helper)
    assert after_status.runs == before.runs and after_status.runs == %{}
    assert after_status.children == %{} and after_status.receipts == %{}
    assert AgentLoopTestModel.dispatched(fixture.model) == []
  end

  # Concept: malformed arguments refuse in ADR 0046's order, never crash the owner.
  # Technical depth: a non-map argument value reaches `invalid_tool_arguments`
  # instead of raising inside the eager refusal checks.
  test "non-map helper arguments refuse invalid_tool_arguments and the owner survives" do
    fixture = Fixture.start([%{text: "unused", calls: []}])
    parent = Fixture.parent(fixture, "parent-create")
    {job, _grant} = helper_job(parent)

    for arguments <- [["inspect"], "inspect", nil] do
      assert Helper.execute(fixture.helper, %{job | validated_arguments: arguments}) ==
               {:error, {:refused_before_effect, :invalid_tool_arguments}}
    end

    assert Process.alive?(fixture.helper)
    assert Helper.status(fixture.helper).runs == %{}
  end

  defp router(fixture) do
    Router.wrap(
      %{
        module: AgentLoopTestExecutor,
        reference: fixture.executor,
        identity: "helper-executor",
        epoch: 1,
        fencing_token: 1,
        workspace_ref: "workspace-ref",
        workspace_lease: "workspace-lease"
      },
      fixture.helper
    ).reference
  end

  defp helper_job(parent, overrides \\ []) do
    unique = System.unique_integer([:positive])
    deadline = System.system_time(:millisecond) + 30_000
    definition = Tool.definition()

    fields =
      Map.merge(
        %{
          protocol_version: 1,
          job_id: "task-#{unique}",
          operation_id: "operation-#{unique}",
          attempt: 1,
          session_id: parent,
          run_id: "run-#{unique}",
          turn_id: "turn",
          tool_call_id: "call",
          origin_session_epoch: 1,
          origin_executor_epoch: 1,
          executor_identity: "helper-executor",
          required_capabilities: [definition["effect_class"]],
          tool_id: definition["tool_id"],
          tool_version: definition["tool_version"],
          effect_class: definition["effect_class"],
          validated_arguments: %{
            "role" => "inspect",
            "description" => "investigate",
            "prompt" => "Inspect the workspace."
          },
          workspace_ref: "workspace-ref",
          workspace_lease: "workspace-lease",
          run_deadline: deadline,
          resource_budgets: %{"max_output_bytes" => 16_384},
          idempotency_class: definition["idempotency_class"],
          fencing_token: 1,
          artifact_policy: %{"retain" => true},
          output_policy: %{"capture" => true}
        },
        Map.new(overrides)
      )

    assert {:ok, job} = Loopex.Executor.job(fields)
    assert {:ok, grant} = Loopex.Executor.issue_grant({:host_policy, :allow}, job, deadline)
    {job, grant}
  end

  defp outcomes(rows) do
    receipts =
      for %{payload: %{kind: "executor_receipt_committed_v2"} = payload} <- rows,
          do: {payload["receipt"]["tool_call_id"], :receipt}

    results =
      for %{payload: %{kind: "tool_result_committed_v2"} = payload} <- rows,
          do: {payload["tool_call_id"], {payload["outcome"], payload["reason"]}}

    Enum.sort(receipts ++ results)
  end

  defp usage(input, output), do: %{input_tokens: input, output_tokens: output}

  @doc false
  def runtime_alias, do: Runtime
end
