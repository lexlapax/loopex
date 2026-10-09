Code.require_file("support/delegation_runtime_fixture.exs", __DIR__)

defmodule LoopexComposition.DelegationHelperTest do
  use ExUnit.Case, async: false

  alias Loopex.{AgentLoopTestExecutor, AgentLoopTestModel, Runtime}
  alias LoopexComposition.Delegation.Helper
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

  defp usage(input, output), do: %{input_tokens: input, output_tokens: output}

  @doc false
  def runtime_alias, do: Runtime
end
