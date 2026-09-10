# Concept: the CLI composition retains an executor result that fits the public
# coding-tool budget through the durable Store boundary.
#
# Technical depth: this deterministic integration case lives outside the
# provider-backed coding-task selector. It drives the real Local executor and
# Store with only the model scripted, then reads both the next model request and
# the committed private receipt.
Code.require_file("../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
Code.require_file("../../loopex/test/support/agent_loop_helper.exs", __DIR__)
Code.require_file("support/demonstration.ex", __DIR__)

defmodule LoopexCli.ReceiptRoundTripTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Loopex.Executor.Local.CodingTools
  alias LoopexCli.Demonstration
  alias LoopexCli.Policy.AllowAll

  setup do
    :persistent_term.erase({AllowAll, :announced})
    :ok
  end

  test "an exact-limit read survives the executor receipt and Store commit" do
    limit = CodingTools.limits().read_bytes
    exact = String.duplicate("x", limit)

    stack =
      stack(
        label: "exact-limit-read",
        script: [
          %{
            text: "reading the exact-limit file",
            calls: [Demonstration.call("c1", "read", %{"path" => "notes.md"})]
          },
          %{text: "done", calls: []}
        ]
      )

    File.write!(Path.join(stack.workspace, "notes.md"), exact)
    {session_id, attachment} = Demonstration.prompt(stack, "read notes.md")
    events = drain(attachment)
    finished = Enum.find(events, &(&1.kind == "run.finished"))

    assert finished["outcome"] == "completed", inspect(events)

    [_first, second] = Loopex.AgentLoopTestModel.dispatched(stack.model)
    tool_result = Enum.find(second.messages, &(&1["role"] == "tool"))
    assert tool_result["outcome"] == "completed"
    assert tool_result["content"] == exact

    receipt =
      stack.store
      |> Demonstration.records(session_id)
      |> Enum.find(&(&1.payload.kind == "executor_receipt_committed"))
      |> get_in([:payload, "receipt"])

    assert receipt["output"] == exact

    assert :ok =
             Loopex.Store.validate_private_record(%{
               "receipt" => receipt,
               kind: "executor_receipt_candidate"
             })
  end

  defp stack(options) do
    {root, workspace} = Demonstration.repository(Keyword.fetch!(options, :label))
    state_root = Path.join(root, "state")

    stack =
      Demonstration.start(Keyword.merge(options, state_root: state_root, workspace: workspace))

    on_exit(fn ->
      Demonstration.stop(stack)
      File.rm_rf(root)
    end)

    Map.merge(stack, %{root: root, state_root: state_root})
  end

  defp drain(attachment, acc \\ [], idle \\ 0) do
    case Loopex.next_event(attachment) do
      {:ok, %{kind: "run.finished"} = event} -> Enum.reverse([event | acc])
      {:ok, event} -> drain(attachment, [event | acc], 0)
      _absent when idle < 800 -> Process.sleep(10) && drain(attachment, acc, idle + 1)
      _absent -> Enum.reverse(acc)
    end
  end
end
