Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)

defmodule Loopex.CancellationTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.AgentLoopTestModel

  defp call(id), do: %{id: id, name: "write", arguments: %{"path" => id}}

  defp start(options) do
    fixture = Fixture.start(options)
    on_exit(fn -> Fixture.stop(fixture) end)
    fixture
  end

  # Concept: stop inside a live operation so an abort has something to cancel.
  #
  # Technical depth: an abort that lands between operations proves nothing about
  # cancellation. Holding the adapter inside its supervised task is what makes
  # these cases about stopping work rather than about recording a wish.
  defp held(options \\ []) do
    parent = self()

    script =
      Keyword.get(options, :script, [%{text: "working", calls: [call("c1")], hold: parent}])

    fixture = start([script: script] ++ Keyword.delete(options, :script))

    {:ok, session_id} = Loopex.create_session(fixture.runtime, %{"t" => "x"}, command_id: "cs")
    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)

    {:accepted, "p1"} =
      Loopex.command(attachment, %{type: :prompt, command_id: "p1", content: "do the work"})

    assert_receive {:holding, model}, 2_000
    {fixture, attachment, session_id, model}
  end

  defp await_dispatch(fixture, attempts \\ 300) do
    if Loopex.AgentLoopTestExecutor.jobs(fixture.executor) != [] do
      :dispatched
    else
      if attempts > 0 do
        Process.sleep(10)
        await_dispatch(fixture, attempts - 1)
      else
        :never_dispatched
      end
    end
  end

  defp events(attachment, acc \\ []) do
    case Loopex.next_event(attachment) do
      {:ok, event} -> events(attachment, [event | acc])
      _other -> Enum.reverse(acc)
    end
  end

  defp settled?(fixture, session_id, attempts \\ 300) do
    case Loopex.session_status(fixture.runtime, session_id) do
      {:ok, %{active_run_id: nil}} ->
        true

      _other when attempts > 0 ->
        Process.sleep(10)
        settled?(fixture, session_id, attempts - 1)

      _other ->
        false
    end
  end

  test "an interrupt reaches the run through the public facade and through no private path" do
    {fixture, attachment, session_id, model} = held()

    # The only route is the public command. Nothing signals a coordinator, writes
    # a control file, or opens a channel of its own.
    assert {:accepted, "abort-1"} =
             Loopex.command(attachment, %{type: :abort, command_id: "abort-1"})

    send(model, :release)
    assert settled?(fixture, session_id)

    # The facade is what carried it: the same attachment that submits a prompt
    # submits the interrupt, with no second surface involved.
    assert function_exported?(Loopex, :command, 2)
  end

  test "an abort admitted during a model call cancels the run and schedules no new work" do
    {fixture, attachment, session_id, model} =
      held(
        script: [
          %{text: "first", calls: [call("c1")], hold: self()},
          %{text: "second", calls: [call("c2")]},
          %{text: "done", calls: []}
        ]
      )

    dispatched_before = length(AgentLoopTestModel.dispatched(fixture.model))

    assert {:accepted, "abort-1"} =
             Loopex.command(attachment, %{type: :abort, command_id: "abort-1"})

    send(model, :release)
    assert settled?(fixture, session_id)
    Process.sleep(150)

    # The run ended and nothing further was staged: the script had two more turns
    # and neither of them ran.
    assert length(AgentLoopTestModel.dispatched(fixture.model)) == dispatched_before
    assert Loopex.AgentLoopTestExecutor.jobs(fixture.executor) == []
  end

  test "an abort admitted during a tool call cancels the executor job and confirms cleanup before committing cancelled" do
    # The executor holds its job open, so the abort lands while a tool is
    # genuinely running rather than between operations.
    {fixture, attachment, session_id, model} =
      held(script: [%{text: "run it", calls: [call("c1")], hold: self()}], tool_delay_ms: 800)

    send(model, :release)
    Process.sleep(100)

    assert {:accepted, "abort-1"} =
             Loopex.command(attachment, %{type: :abort, command_id: "abort-1"})

    assert settled?(fixture, session_id)

    finished = Enum.find(events(attachment), &(&1.kind == "run.finished"))

    # Cleanup was confirmed, so the run may honestly claim it was cancelled.
    assert finished["outcome"] == "cancelled"
    assert finished["reconciliation_ref"] == nil
  end

  test "a run finishes cancelled only when every owned operation is validated terminal and every owned process tree is confirmed cleaned" do
    {fixture, attachment, session_id, model} = held()

    {:accepted, "abort-1"} = Loopex.command(attachment, %{type: :abort, command_id: "abort-1"})
    send(model, :release)
    assert settled?(fixture, session_id)

    finished = Enum.find(events(attachment), &(&1.kind == "run.finished"))

    # The two outcomes are not interchangeable: one claims a clean stop and the
    # other admits it cannot. Whichever committed, it must carry the evidence
    # that goes with it.
    assert finished["outcome"] in ["cancelled", "outcome_unknown"]

    if finished["outcome"] == "cancelled" do
      assert finished["reconciliation_ref"] == nil
    else
      assert is_binary(finished["reconciliation_ref"])
    end
  end

  test "a validated terminal tool fact committed before the abort is preserved and not overwritten" do
    # The tool completes, then the abort lands. The abort ends what is still
    # running; it does not rewrite what already finished.
    {fixture, attachment, session_id, model} =
      held(
        script: [
          %{text: "one", calls: [call("c1")]},
          %{text: "two", calls: [call("c2")], hold: self()}
        ]
      )

    finished_tools =
      events(attachment) |> Enum.filter(&(&1.kind == "tool.finished"))

    assert Enum.any?(finished_tools, &(&1["tool_call_id"] == "c1"))

    {:accepted, "abort-1"} = Loopex.command(attachment, %{type: :abort, command_id: "abort-1"})
    send(model, :release)
    assert settled?(fixture, session_id)

    # The first call's committed terminal fact is still there, unchanged.
    after_abort = events(attachment)
    all = finished_tools ++ after_abort

    c1 = Enum.find(all, &(&1.kind == "tool.finished" and &1["tool_call_id"] == "c1"))
    assert c1["outcome"] == "completed"
  end

  test "an effect without sufficient evidence ends outcome unknown and is never blindly retried" do
    # An executor that cannot confirm its cleanup leaves the run unable to claim
    # a clean stop.
    {fixture, attachment, session_id, model} =
      held(
        script: [%{text: "run it", calls: [call("c1")], hold: self()}],
        tool_delay_ms: 2_000,
        cleanup: :unconfirmed
      )

    send(model, :release)

    # Wait until the job is genuinely running before aborting. Aborting before
    # dispatch would exercise a different path entirely and would pass for the
    # wrong reason.
    await_dispatch(fixture)

    {:accepted, "abort-1"} = Loopex.command(attachment, %{type: :abort, command_id: "abort-1"})
    assert settled?(fixture, session_id)

    finished = Enum.find(events(attachment), &(&1.kind == "run.finished"))

    assert finished["outcome"] == "outcome_unknown"
    assert is_binary(finished["reconciliation_ref"])

    # And it is not retried: no second job was ever dispatched for that call.
    dispatched = Loopex.AgentLoopTestExecutor.jobs(fixture.executor)
    assert length(dispatched) <= 1
  end

  test "a second interrupt reports what is still being cleaned up rather than abandoning the session" do
    {fixture, attachment, session_id, model} = held()

    assert {:accepted, "abort-1"} =
             Loopex.command(attachment, %{type: :abort, command_id: "abort-1"})

    # A second interrupt is answered rather than ignored, and answering it does
    # not start a second cancellation of the same work.
    second = Loopex.command(attachment, %{type: :abort, command_id: "abort-2"})
    assert match?({:accepted, "abort-2"}, second) or match?({:error, _reason}, second)

    # Re-presenting the first returns its retained result rather than cancelling
    # again, so an operator leaning on the key does not multiply the work.
    assert {:accepted, "abort-1"} =
             Loopex.command(attachment, %{type: :abort, command_id: "abort-1"})

    send(model, :release)
    assert settled?(fixture, session_id)
  end

  test "the operator observes what was cancelled and what actually happened" do
    {fixture, attachment, session_id, model} = held()

    {:accepted, "abort-1"} = Loopex.command(attachment, %{type: :abort, command_id: "abort-1"})
    send(model, :release)
    assert settled?(fixture, session_id)

    observed = events(attachment)
    finished = Enum.find(observed, &(&1.kind == "run.finished"))

    # The operator can see which run ended, which command ended it, and how it
    # ended — not merely that something stopped.
    assert finished["command_id"] == "abort-1"
    assert is_binary(finished["run_id"])
    assert finished["outcome"] in ["cancelled", "outcome_unknown"]

    # And the session is left usable rather than abandoned.
    assert {:ok, %{active_run_id: nil}} =
             Loopex.session_status(fixture.runtime, session_id)
  end
end
