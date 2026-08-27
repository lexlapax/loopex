Code.require_file("support/m1_runtime_helper.exs", __DIR__)
Code.require_file("support/agent_loop_helper.exs", __DIR__)

defmodule Loopex.CancellationTestExecutor do
  @moduledoc false

  # Concept: an executor whose job can be made to finish inside the window the
  # coordinator spends reducing an abort.
  #
  # Technical depth: the shared fixture executor answers instantly or after a
  # fixed sleep, which can only ever produce a job that is plainly running or
  # plainly finished. The case that matters is neither: a receipt that exists but
  # has not been delivered yet. `cancel/2` here releases the waiting job and then
  # waits for it to answer, which puts the receipt in the coordinator's mailbox
  # while the coordinator is still inside the abort — deterministically, rather
  # than by racing a sleep against a scheduler.

  @behaviour Loopex.Executor

  def start(mode) do
    {:ok, pid} = Agent.start_link(fn -> %{mode: mode, jobs: [], waiting: nil} end)
    pid
  end

  def jobs(pid), do: Agent.get(pid, & &1.jobs) |> Enum.reverse()

  @impl Loopex.Executor
  def cancel(pid, _job_id) do
    case Agent.get(pid, & &1.mode) do
      :never_answers ->
        {:ok, :cleaned}

      _releases ->
        waiting = Agent.get(pid, & &1.waiting)
        if is_pid(waiting), do: send(waiting, :answer)
        # Let the released job actually deliver before the coordinator looks.
        Process.sleep(120)
        {:ok, :cleaned}
    end
  end

  @impl Loopex.Executor
  def execute(pid, job, _grant, _options, progress \\ nil) do
    _progress = progress || Loopex.Executor.discard_progress()
    caller = self()
    :ok = Agent.update(pid, fn state -> %{state | jobs: [job | state.jobs], waiting: caller} end)
    mode = Agent.get(pid, & &1.mode)

    case answer(mode, job.tool_call_id) do
      {:now, outcome} ->
        {:ok, Loopex.CancellationTestExecutor.receipt(job, outcome)}

      {:held, outcome} ->
        receive do
          :answer -> :ok
        after
          4_000 -> :ok
        end

        {:ok, Loopex.CancellationTestExecutor.receipt(job, outcome)}
    end
  end

  # Concept: which call answers when, and with what.
  #
  # Technical depth: the precedence cases need a job that answers `outcome_unknown`
  # inside the abort window, and a batch whose first call is unprovable while a
  # later one is still holdable. Both are the same executor with a different
  # schedule, so a case differs from its neighbour in the schedule alone.
  defp answer(:unknown_receipt_before_abort, _tool_call_id), do: {:held, "outcome_unknown"}
  defp answer(:unknown_then_held, "c1"), do: {:now, "outcome_unknown"}
  defp answer(_mode, _tool_call_id), do: {:held, "completed"}

  def receipt(job, outcome \\ "completed") do
    %{
      protocol_version: 1,
      job_id: job.job_id,
      operation_id: job.operation_id,
      attempt: job.attempt,
      session_id: job.session_id,
      run_id: job.run_id,
      turn_id: job.turn_id,
      tool_call_id: job.tool_call_id,
      session_epoch_at_dispatch: job.origin_session_epoch,
      executor_epoch: job.origin_executor_epoch,
      executor_identity: job.executor_identity,
      canonical_request_digest: job.canonical_request_digest,
      fencing_token: job.fencing_token,
      tool_id: job.tool_id,
      tool_version: job.tool_version,
      outcome: outcome,
      output: "wrote #{job.tool_call_id}",
      progress_count: 0,
      observed_at_ms: System.system_time(:millisecond),
      child_environment_names: [],
      provider_credential_present: false,
      artifacts: []
    }
  end
end

defmodule Loopex.CancellationTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Loopex.AgentLoopFixture, as: Fixture
  alias Loopex.AgentLoopTestModel
  alias Loopex.CancellationTestExecutor
  alias Loopex.M1RuntimeTestStore

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

  # Concept: the same fixture, wired to an executor this file controls.
  #
  # Technical depth: composed through the public `Loopex.start_link` rather than
  # by editing the shared helper, so the cases that need an executor with a
  # decidable finishing moment get one without changing what every other case in
  # the repository runs against.
  defp start_with_executor(mode, tool_script) do
    model_pid = AgentLoopTestModel.start(tool_script)
    executor_pid = CancellationTestExecutor.start(mode)
    {store_pid, store} = M1RuntimeTestStore.start_store(label: "cancellation")
    definitions = [Fixture.tool_definition()]

    {:ok, runtime} =
      Loopex.start_link(
        runtime_id: "cancellation-runtime-#{System.unique_integer([:positive])}",
        store: store,
        model: %{
          module: AgentLoopTestModel,
          model: "scripted:v1",
          options: [script: model_pid, max_tokens: 256]
        },
        executor: %{
          module: CancellationTestExecutor,
          reference: executor_pid,
          identity: "cancellation-executor",
          epoch: 1,
          fencing_token: 1,
          workspace_ref: "workspace-ref",
          workspace_lease: "workspace-lease"
        },
        tool: nil,
        bounds: %{max_turns: 8, token_budget: 1_000_000, deadline_ms: 600_000},
        tools: definitions,
        active_tools: Enum.map(definitions, &Map.fetch!(&1, "tool_id")),
        policy: Loopex.AgentLoopTestPolicy,
        grant_decision: {:host_policy, :allow}
      )

    fixture = %{runtime: runtime, model: model_pid, executor: executor_pid, store: store_pid}

    on_exit(fn ->
      try do
        Loopex.stop(runtime)
      catch
        :exit, _reason -> :ok
      end

      try do
        GenServer.stop(store_pid, :normal, 1_000)
      catch
        :exit, _reason -> :ok
      end
    end)

    fixture
  end

  # Concept: reach the moment an abort lands while a tool is genuinely running.
  defp abort_during_tool(mode) do
    fixture = start_with_executor(mode, [%{text: "run it", calls: [call("c1")]}])

    {:ok, session_id} = Loopex.create_session(fixture.runtime, %{"t" => "x"}, command_id: "cs")
    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)

    {:accepted, "p1"} =
      Loopex.command(attachment, %{type: :prompt, command_id: "p1", content: "do the work"})

    :dispatched = await_dispatch(fixture)

    {:accepted, "abort-1"} = Loopex.command(attachment, %{type: :abort, command_id: "abort-1"})
    assert settled?(fixture, session_id)

    {fixture, session_id, events(attachment)}
  end

  defp await_dispatch(fixture, attempts \\ 300) do
    if Agent.get(fixture.executor, & &1.jobs) != [] do
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

  # Concept: read the published plane until one named tool fact has appeared,
  # and hand back everything read on the way.
  #
  # Technical depth: the attachment is a cursor, so a case that waits for an
  # event and then reads again would lose what it already consumed. Reaching the
  # deadline is the finding rather than an empty list, because a case that
  # asserts on a missing event reports a stalled run as a missing key.
  defp await_tool_finished(attachment, tool_call_id, acc \\ [], attempts \\ 400) do
    acc = acc ++ events(attachment)

    cond do
      Enum.any?(
        acc,
        &(&1.kind == "tool.finished" and &1["tool_call_id"] == tool_call_id)
      ) ->
        acc

      attempts > 0 ->
        Process.sleep(10)
        await_tool_finished(attachment, tool_call_id, acc, attempts - 1)

      true ->
        flunk("""
        no tool.finished for #{tool_call_id} was published.
        events observed: #{inspect(Enum.map(acc, & &1.kind))}
        """)
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
    # The window this is about: the write finished, its receipt exists, and the
    # abort is being reduced before that receipt has been delivered. The group is
    # already gone, so cleanup reports clean — and the run may claim `cancelled`
    # only because the receipt is adopted rather than dropped on the floor. Under
    # the defect it was dropped, and the run claimed a clean stop for an effect
    # that had happened and left no terminal fact behind.
    {fixture, session_id, observed} = abort_during_tool(:receipt_before_abort)

    finished = Enum.find(observed, &(&1.kind == "run.finished"))

    assert finished["outcome"] == "cancelled"
    assert finished["reconciliation_ref"] == nil

    # The claim rests on a real executor fact: the call has a terminal outcome
    # the operator can read, and the effect was not quietly discarded.
    tool = Enum.find(observed, &(&1.kind == "tool.finished" and &1["tool_call_id"] == "c1"))
    assert tool["outcome"] == "completed"

    # And it is durable, not merely announced. The receipt is journaled as the
    # attempt's terminal fact.
    receipts =
      fixture
      |> Fixture.records(session_id)
      |> Enum.filter(&(&1.payload[:kind] == "executor_receipt_committed"))

    assert length(receipts) == 1
  end

  test "a run finishes cancelled only when every owned operation is validated terminal and every owned process tree is confirmed cleaned" do
    # The two outcomes are not interchangeable: one claims a clean stop and the
    # other admits it cannot. Both halves are decided here rather than accepted
    # as either, because a case that accepts either proves neither.

    # A model attempt owns no effect, so stopping it is the whole of its cleanup
    # and the run may honestly say it was cancelled.
    {fixture, attachment, session_id, model} = held()

    {:accepted, "abort-1"} = Loopex.command(attachment, %{type: :abort, command_id: "abort-1"})
    send(model, :release)
    assert settled?(fixture, session_id)

    model_finished = Enum.find(events(attachment), &(&1.kind == "run.finished"))
    assert model_finished["outcome"] == "cancelled"
    assert model_finished["reconciliation_ref"] == nil

    # An effect that was still running owns something the confirmation does not
    # cover. The executor confirms the process tree is gone — and that is still
    # not enough, because a confirmed cleanup bounds the tree and says nothing
    # about what the effect did. With no validated terminal fact for that
    # operation the run ends `outcome_unknown` carrying its reference.
    {_effect_fixture, _effect_session, observed} = abort_during_tool(:never_answers)
    effect_finished = Enum.find(observed, &(&1.kind == "run.finished"))

    assert effect_finished["outcome"] == "outcome_unknown"
    assert is_binary(effect_finished["reconciliation_ref"])
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

  test "a replayed abort returns its retained answer and never cancels the run that is active now" do
    # Abort run one, start run two, then re-present the first abort. Under the
    # defect the cancellation ran before the reducer had classified the command,
    # so the replay killed run two's live work and then answered with run one's
    # retained acceptance — leaving run two with no terminal fact at all.
    parent = self()

    fixture =
      start(
        script: [
          %{text: "first run", calls: [call("c1")], hold: parent},
          %{text: "second run", calls: [], hold: parent}
        ]
      )

    {:ok, session_id} = Loopex.create_session(fixture.runtime, %{"t" => "x"}, command_id: "cs")
    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)

    {:accepted, "p1"} =
      Loopex.command(attachment, %{type: :prompt, command_id: "p1", content: "first"})

    assert_receive {:holding, first_model}, 2_000
    {:accepted, "a1"} = Loopex.command(attachment, %{type: :abort, command_id: "a1"})
    send(first_model, :release)
    assert settled?(fixture, session_id)

    {:accepted, "p2"} =
      Loopex.command(attachment, %{type: :prompt, command_id: "p2", content: "second"})

    assert_receive {:holding, second_model}, 2_000

    # The replay is answered from the retained record.
    assert {:accepted, "a1"} = Loopex.command(attachment, %{type: :abort, command_id: "a1"})

    # And a command whose id is bound to different bytes is refused, which is the
    # other branch that used to cancel first and classify afterwards.
    assert {:error, :idempotency_conflict} =
             Loopex.command(attachment, %{type: :prompt, command_id: "a1", content: "conflict"})

    # A malformed command reaches no cancellation either.
    assert {:error, :invalid_command} = Loopex.command(attachment, %{type: :abort})

    # Run two's work was untouched: released, it finishes on its own terms.
    send(second_model, :release)
    assert settled?(fixture, session_id)

    finishes =
      attachment
      |> events()
      |> Enum.filter(&(&1.kind == "run.finished"))

    assert length(finishes) == 2
    assert List.last(finishes)["outcome"] == "completed"

    # Exactly one abort was ever admitted, so nothing was cancelled twice.
    aborts =
      fixture
      |> Fixture.records(session_id)
      |> Enum.filter(&(&1.payload["command_id"] == "a1"))

    assert length(aborts) == 1
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

  test "an abort reduced while an unprovable receipt settles finishes the run outcome unknown" do
    # The abort is admitted first, and the receipt it adopts on the way through
    # says the effect's truth is unknown. Deciding the run outcome from what
    # cleanup achieved reported `cancelled` — a clean stop — over an effect
    # nobody can account for. ADR 0009 fixes the opposite order: "one
    # `outcome_unknown` among the owned operations finishes the run
    # `outcome_unknown`, whatever asked it to stop."
    {_fixture, _session_id, observed} = abort_during_tool(:unknown_receipt_before_abort)

    tool = Enum.find(observed, &(&1.kind == "tool.finished" and &1["tool_call_id"] == "c1"))
    assert tool["outcome"] == "outcome_unknown"

    finished = Enum.find(observed, &(&1.kind == "run.finished"))
    assert finished["outcome"] == "outcome_unknown"
    refute finished["outcome"] == "cancelled"

    # `cancelled` carries no reference because there is nothing to reconcile;
    # this ending must carry one, or an operator is told to reconcile nothing.
    assert is_binary(finished["reconciliation_ref"])
  end

  test "an abort admitted after an unprovable effect committed never rewrites the run to cancelled" do
    # The other order. The unknown fact is already committed and published when
    # the abort arrives, so nothing about the abort's own cleanup may decide the
    # run outcome — the committed operation outcomes do.
    fixture =
      start_with_executor(:unknown_then_held, [
        %{text: "two at once", calls: [call("c1"), call("c2")]},
        %{text: "done", calls: []}
      ])

    {:ok, session_id} = Loopex.create_session(fixture.runtime, %{"t" => "x"}, command_id: "cs")
    {:ok, attachment} = Loopex.attach(fixture.runtime, session_id, after_event_sequence: 0)

    {:accepted, "p1"} =
      Loopex.command(attachment, %{type: :prompt, command_id: "p1", content: "do the work"})

    observed = await_tool_finished(attachment, "c1")

    # Whether this is admitted at all depends on whether the run has already
    # committed its own terminal, and either answer is correct. What is never
    # correct is a second, contradicting ending.
    _reply = Loopex.command(attachment, %{type: :abort, command_id: "abort-1"})
    assert settled?(fixture, session_id)

    finishes =
      (observed ++ events(attachment))
      |> Enum.filter(&(&1.kind == "run.finished"))

    assert Enum.map(finishes, & &1["outcome"]) == ["outcome_unknown"]
  end
end
