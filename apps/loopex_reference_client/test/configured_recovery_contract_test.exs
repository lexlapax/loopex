Code.require_file("support/runtime_fixture.ex", __DIR__)

# An executor that runs and cancels exactly as the shipped local one does, but
# cannot say what it retained: every receipt lookup is answered as a job still
# in flight.
defmodule Loopex.ReferenceClient.InFlightReceiptExecutor do
  @moduledoc false
  @behaviour Loopex.Executor

  alias Loopex.Executor.Local

  @impl Loopex.Executor
  def execute(reference, job, grant, options, progress),
    do: Local.execute(reference, job, grant, options, progress)

  @impl Loopex.Executor
  def cancel(reference, job_id), do: Local.cancel(reference, job_id)

  @impl Loopex.Executor
  def retained_receipt(_reference, _job_id), do: {:error, :effect_in_flight}
end

# An executor that lets the shipped Local hand finish its complete durable
# settlement, then holds the exact answer before the session coordinator can
# journal it. Stopping the runtime at that boundary reproduces an origin lost
# after the hand's truth exists without depending on a success-only kernel hook.
defmodule Loopex.ReferenceClient.HeldSettlementExecutor do
  @moduledoc false
  @behaviour Loopex.Executor

  alias Loopex.Executor.Local

  @impl Loopex.Executor
  def execute(%{local: local, observer: observer}, job, grant, options, progress) do
    result = Local.execute(local, job, grant, options, progress)
    send(observer, {:executor_settlement_held, self(), job.job_id, result})

    receive do
      {:release_executor_settlement, job_id} when job_id == job.job_id -> result
    end
  end

  @impl Loopex.Executor
  def cancel(%{local: local}, job_id), do: Local.cancel(local, job_id)

  @impl Loopex.Executor
  def retained_receipt(%{local: local}, job_id), do: Local.receipt(local, job_id)
end

defmodule Loopex.ReferenceClient.ConfiguredRecoveryContractTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Loopex.Executor
  alias Loopex.Executor.Local
  alias Loopex.ReferenceClient
  alias Loopex.ReferenceClient.HeldSettlementExecutor
  alias Loopex.ReferenceClient.InFlightReceiptExecutor
  alias Loopex.ReferenceClient.Recovery
  alias Loopex.ReferenceClientRuntimeFixture, as: Fixture

  test "a non-default cleanup value crosses real Local receipt restart prepared resume and cancel recovery" do
    label = "configured-cancel-recovery"
    cleanup_grace_ms = 7_311
    relative_path = "#{label}.txt"
    content = "effect-#{label}"

    base =
      Fixture.start(
        label,
        Loopex.ReferenceClientTestModel,
        [relative_path: relative_path, content: content, observer: self()],
        fault_to: self()
      )

    on_exit(fn -> File.rm_rf!(base.root) end)
    on_exit(fn -> Fixture.stop(base, false) end)

    Fixture.stop_runtime(base)
    runtime_options = Keyword.put(base.runtime_options, :cleanup_grace_ms, cleanup_grace_ms)
    assert {:ok, client} = ReferenceClient.start(runtime_options)

    fixture =
      %{base | client: client, runtime_options: runtime_options}
      |> Fixture.create(label)

    on_exit(fn -> Fixture.stop(fixture, false) end)

    session_id = fixture.client.session_id
    assert {:ok, %{status: :active}} = ReferenceClient.status(fixture.client)

    assert Local.cleanup_grace_ms(fixture.executor) ==
             Loopex.Executor.default_cleanup_grace_ms()

    refute Local.cleanup_grace_ms(fixture.executor) == cleanup_grace_ms

    prompt_id = "prompt-#{label}"
    assert {:accepted, ^prompt_id} = ReferenceClient.prompt(fixture.client, prompt_id, "do it")
    assert_receive {:model_request, _request}, 3_000

    assert_receive {:loopex_fault, :after_executor_receipt_before_fact, _coordinator, _reference,
                    retained},
                   3_000

    assert Local.stats(fixture.executor).dispatches[retained.job_id] == 1
    assert {:ok, ^retained} = Local.receipt(fixture.executor, retained.job_id)

    effect_path = Path.join(fixture.workspace, relative_path)
    assert File.read!(effect_path) == content

    old_runtime = fixture.client.runtime
    assert {:ok, old_runtime_children} = Loopex.Runtime.children(old_runtime)

    old_runtime_processes =
      [old_runtime.supervisor | Map.values(old_runtime_children)]

    old_processes = [fixture.store_pid, fixture.lease, fixture.executor]
    root = fixture.root

    Fixture.stop(fixture, false)

    refute Loopex.Runtime.alive?(old_runtime)
    for process <- old_runtime_processes, do: refute(Process.alive?(process))
    for process <- old_processes, do: refute(Process.alive?(process))

    restarted =
      Fixture.start(
        label,
        Loopex.ReferenceClientTestModel,
        [relative_path: relative_path, content: content, observer: self()],
        root: root,
        recover_stale_writer: true
      )

    on_exit(fn -> Fixture.stop(restarted, false) end)

    assert {:ok, restarted_runtime_children} =
             Loopex.Runtime.children(restarted.client.runtime)

    for process <- [restarted.client.runtime.supervisor | Map.values(restarted_runtime_children)] do
      refute process in old_runtime_processes
      assert Process.alive?(process)
    end

    for process <- [restarted.store_pid, restarted.lease, restarted.executor] do
      refute process in old_processes
      assert Process.alive?(process)
    end

    assert {:ok, {:prepared, activation}} =
             invoke_additive(Loopex, :prepare_resume_session, [
               restarted.client.runtime,
               session_id,
               "prepare-#{label}"
             ])

    assert {:ok, %{cleanup_grace_ms: ^cleanup_grace_ms, active_run_id: active_run_id}} =
             Loopex.session_status(restarted.client.runtime, session_id)

    assert is_binary(active_run_id)
    assert retained.cleanup_grace_ms == cleanup_grace_ms
    assert {:ok, ^retained} = Local.receipt(restarted.executor, retained.job_id)
    assert Local.stats(restarted.executor).dispatches == %{}

    assert {:ok, attachment} =
             Loopex.attach(restarted.client.runtime, session_id, after_event_sequence: 0)

    refute_receive {:model_request, _request}, 200
    assert Local.stats(restarted.executor).dispatches == %{}
    assert File.read!(effect_path) == content

    # Reconciliation is host-driven: the host presents the retained receipt to
    # the solicited query before it cancels, so the abort settles the run over a
    # committed effect fact rather than over an unproved one.
    host = %{restarted.client | attachment: attachment}
    assert {:ok, query} = ReferenceClient.reconciliation_query(host)
    assert :ok = ReferenceClient.reconcile(host, Recovery.receipt(query, retained))

    cancel_id = "cancel-#{label}"

    assert {:accepted, ^cancel_id} =
             Loopex.command(attachment, %{type: :abort, command_id: cancel_id})

    assert_refused(invoke_additive(Loopex, :activate_resume, [activation]))

    terminal = await_run_finished(attachment, 10_000)
    assert terminal["command_id"] == cancel_id
    assert terminal["outcome"] == "cancelled"
    assert terminal["cleanup_grace_ms"] == cleanup_grace_ms

    refute_receive {:model_request, _request}, 200
    assert Local.stats(restarted.executor).dispatches == %{}
    assert File.read!(effect_path) == content
  end

  test "prepared restart activation reconciles the retained effect once without redispatch" do
    label = "configured-resume-recovery"
    cleanup_grace_ms = 7_311
    relative_path = "#{label}.txt"
    content = "effect-#{label}"

    base =
      Fixture.start(
        label,
        Loopex.ReferenceClientTestModel,
        [relative_path: relative_path, content: content, observer: self()],
        fault_to: self()
      )

    on_exit(fn -> File.rm_rf!(base.root) end)
    on_exit(fn -> Fixture.stop(base, false) end)

    Fixture.stop_runtime(base)
    runtime_options = Keyword.put(base.runtime_options, :cleanup_grace_ms, cleanup_grace_ms)
    assert {:ok, client} = ReferenceClient.start(runtime_options)

    fixture =
      %{base | client: client, runtime_options: runtime_options}
      |> Fixture.create(label)

    on_exit(fn -> Fixture.stop(fixture, false) end)

    session_id = fixture.client.session_id
    prompt_id = "prompt-#{label}"
    assert {:accepted, ^prompt_id} = ReferenceClient.prompt(fixture.client, prompt_id, "do it")
    assert_receive {:model_request, _request}, 3_000

    assert_receive {:loopex_fault, :after_executor_receipt_before_fact, _coordinator, _reference,
                    retained},
                   3_000

    effect_path = Path.join(fixture.workspace, relative_path)
    assert File.read!(effect_path) == content
    assert Local.stats(fixture.executor).dispatches[retained.job_id] == 1

    root = fixture.root
    Fixture.stop(fixture, false)

    restarted =
      Fixture.start(
        label,
        Loopex.ReferenceClientTestModel,
        [relative_path: relative_path, content: content, observer: self()],
        root: root,
        recover_stale_writer: true
      )

    on_exit(fn -> Fixture.stop(restarted, false) end)

    assert {:ok, {:prepared, activation}} =
             invoke_additive(Loopex, :prepare_resume_session, [
               restarted.client.runtime,
               session_id,
               "prepare-activate-#{label}"
             ])

    assert {:ok, attachment} =
             Loopex.attach(restarted.client.runtime, session_id, after_event_sequence: 0)

    refute_receive {:model_request, _request}, 200
    assert Local.stats(restarted.executor).dispatches == %{}

    assert {:ok, ^session_id} = invoke_additive(Loopex, :activate_resume, [activation])
    assert_refused(invoke_additive(Loopex, :activate_resume, [activation]))

    # Concept: activation settles the effect from what the executor retained;
    # no host has to ask.
    #
    # Technical depth: the coordinator solicits its own query at activation,
    # reads the receipt through the executor port's optional `retained_receipt/2`, and
    # validates it exactly as it validates a host's answer. A host that asks
    # afterwards finds nothing pending, which is the proof the kernel did it.
    terminal = await_run_finished(attachment, 10_000)
    assert terminal["outcome"] == "completed"
    assert terminal["cleanup_grace_ms"] == cleanup_grace_ms
    assert retained.cleanup_grace_ms == cleanup_grace_ms
    assert {:ok, ^retained} = Local.receipt(restarted.executor, retained.job_id)

    host = %{restarted.client | attachment: attachment}
    assert {:error, :no_effect_recovery_pending} = ReferenceClient.reconciliation_query(host)

    # Completing the turn after the reconciled tool result takes one further
    # model call; the effect itself is proved not re-run below.
    assert_receive {:model_request, _request}, 3_000
    assert Local.stats(restarted.executor).dispatches == %{}
    assert File.read!(effect_path) == content
  end

  # Concept: an effect the dead process never accounted for ends
  # `outcome_unknown` at activation, and is never run again to find out.
  #
  # Technical depth: with the receipt removed, the executor answers `:absent`
  # and the coordinator commits the same `outcome_unknown` a host's
  # `Recovery.outcome_unknown/1` would. The effect's bytes are still on disk
  # and the dispatch count stays zero: absence settled the run, it did not
  # retry it.
  test "prepared activation without a retained receipt ends outcome_unknown without redispatch" do
    {restarted, attachment, retained} =
      restart_prepared("activation-without-receipt", remove_receipt: true)

    assert :absent = Local.receipt(restarted.executor, retained.job_id)

    terminal = await_run_finished(attachment, 10_000)
    assert terminal["outcome"] == "outcome_unknown"
    assert Local.stats(restarted.executor).dispatches == %{}

    host = %{restarted.client | attachment: attachment}
    assert {:error, :no_effect_recovery_pending} = ReferenceClient.reconciliation_query(host)
  end

  # Concept: an effect whose open entry the dead process never disposed of ends
  # the recovered run `outcome_unknown`, and the root stays quarantined.
  #
  # Technical depth: the origin's settlement is made to fail its open-entry
  # removal through the executor's `open_authority_close` seam. Local finishes
  # that settlement before a port wrapper holds its unresolved answer, so the
  # proved completed receipt is durable, the open entry still stands, and no
  # root claim is stranded when the origin runtime dies. The restarted executor
  # therefore answers `effect_settling` for that job, and activation ends the
  # run `outcome_unknown` rather than waiting on a disposition nobody will
  # finish; the next admission on that root is still refused, which is the
  # quarantine doing its job.
  test "prepared activation over a quarantined root ends outcome_unknown and keeps the quarantine" do
    {restarted, attachment, retained} =
      restart_prepared("activation-quarantined",
        hold_settlement: true,
        origin_executor_options: [open_authority_close: fn _ledger, _job_id -> {:error, :eio} end]
      )

    assert retained.outcome == :completed
    assert retained.cleanup_confirmation == :confirmed
    assert {:error, :effect_settling} = Local.receipt(restarted.executor, retained.job_id)

    terminal = await_run_finished(attachment, 10_000)
    assert terminal["outcome"] == "outcome_unknown"
    assert_quarantine_refuses_unrelated_effect(restarted, "activation-quarantined")
    assert Local.stats(restarted.executor).dispatches == %{}

    host = %{restarted.client | attachment: attachment}
    assert {:error, :no_effect_recovery_pending} = ReferenceClient.reconciliation_query(host)
  end

  # Concept: an executor that cannot say leaves the reconciliation to the host,
  # exactly as before.
  #
  # Technical depth: the wrapper answers `effect_in_flight` to every lookup, so
  # the coordinator declines rather than settling on an answer it could not
  # validate; the run stays pending, the host's query is solicited fresh, and
  # the host's receipt completes the run. Silence is never read as absence.
  test "prepared activation leaves an unanswerable receipt lookup to the host" do
    {restarted, attachment, retained} =
      restart_prepared("activation-declined", executor_module: InFlightReceiptExecutor)

    refute_receive {:model_request, _request}, 500
    assert await_run_finished_or_pending(attachment, 500) == :pending

    host = %{restarted.client | attachment: attachment}
    assert {:ok, query} = ReferenceClient.reconciliation_query(host)
    assert :ok = ReferenceClient.reconcile(host, Recovery.receipt(query, retained))

    terminal = await_run_finished(attachment, 10_000)
    assert terminal["outcome"] == "completed"
    assert Local.stats(restarted.executor).dispatches == %{}
  end

  defp restart_prepared(label, options) do
    relative_path = "#{label}.txt"
    content = "effect-#{label}"

    hold_settlement? = Keyword.get(options, :hold_settlement, false)
    observer = self()

    origin_runtime_options =
      if hold_settlement? do
        [
          executor_module: HeldSettlementExecutor,
          executor_reference_builder: fn local -> %{local: local, observer: observer} end
        ]
      else
        []
      end

    fixture =
      Fixture.start(
        label,
        Loopex.ReferenceClientTestModel,
        [relative_path: relative_path, content: content, observer: self()],
        [fault_to: self()] ++
          origin_runtime_options ++
          Keyword.take(
            Keyword.get(options, :origin_executor_options, []) |> then(&[executor_options: &1]),
            [:executor_options]
          )
      )
      |> Fixture.create(label)

    on_exit(fn -> File.rm_rf!(fixture.root) end)
    on_exit(fn -> Fixture.stop(fixture, false) end)

    session_id = fixture.client.session_id
    assert {:accepted, _id} = ReferenceClient.prompt(fixture.client, "prompt-#{label}", "do it")
    assert_receive {:model_request, _request}, 3_000

    retained =
      if hold_settlement? do
        assert_receive {:executor_settlement_held, worker, job_id,
                        {:error, {:effect_settling, {:open_authority_not_removed, :eio}}}},
                       3_000

        retained = retained_receipt!(fixture.ledger, job_id)
        worker_monitor = Process.monitor(worker)
        Fixture.stop_runtime(fixture)
        assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}, 3_000
        assert {:error, :effect_settling} = Local.receipt(fixture.executor, job_id)
        retained
      else
        assert_receive {:loopex_fault, :after_executor_receipt_before_fact, _coordinator,
                        _reference, retained},
                       3_000

        retained
      end

    assert File.read!(Path.join(fixture.workspace, relative_path)) == content

    if Keyword.get(options, :remove_receipt) do
      File.rm!(receipt_path(fixture.ledger, retained.job_id))
    end

    root = fixture.root
    Fixture.stop(fixture, false)

    restart_options =
      Keyword.merge(
        [root: root, recover_stale_writer: true],
        Keyword.take(options, [:executor_module])
      )

    restarted =
      Fixture.start(
        label,
        Loopex.ReferenceClientTestModel,
        [relative_path: relative_path, content: content, observer: self()],
        restart_options
      )

    on_exit(fn -> Fixture.stop(restarted, false) end)

    assert {:ok, {:prepared, activation}} =
             invoke_additive(Loopex, :prepare_resume_session, [
               restarted.client.runtime,
               session_id,
               "prepare-#{label}"
             ])

    assert {:ok, attachment} =
             Loopex.attach(restarted.client.runtime, session_id, after_event_sequence: 0)

    assert {:ok, ^session_id} = invoke_additive(Loopex, :activate_resume, [activation])
    {restarted, attachment, retained}
  end

  defp receipt_path(ledger, job_id) do
    name = :crypto.hash(:sha256, job_id) |> Base.encode16(case: :lower)
    Path.join(ledger, name <> ".receipt")
  end

  defp retained_receipt!(ledger, job_id) do
    ledger
    |> receipt_path(job_id)
    |> File.read!()
    |> :erlang.binary_to_term([:safe])
  end

  defp assert_quarantine_refuses_unrelated_effect(fixture, label) do
    now = System.system_time(:millisecond)
    proof = "#{label}-unrelated"
    target = "#{proof}.txt"
    {:ok, tool} = Local.tool("loopex.demo.write")

    {:ok, job} =
      Executor.job(%{
        protocol_version: 1,
        job_id: "job-#{proof}",
        operation_id: "operation-#{proof}",
        attempt: 1,
        session_id: "session-#{proof}",
        run_id: "run-#{proof}",
        turn_id: "turn-#{proof}",
        tool_call_id: "tool-call-#{proof}",
        origin_session_epoch: 1,
        origin_executor_epoch: 11,
        executor_identity: "executor-local",
        required_capabilities: [tool.effect_class],
        tool_id: tool.id,
        tool_version: tool.version,
        effect_class: tool.effect_class,
        validated_arguments: %{"relative_path" => target, "content" => "must-not-run"},
        workspace_ref: "workspace-#{label}",
        workspace_lease: "lease-#{label}",
        run_deadline: now + 60_000,
        resource_budgets: %{
          "max_output_bytes" => 1_048_576,
          "max_wall_time_ms" => 30_000
        },
        idempotency_class: "reconcile_then_retry",
        fencing_token: 73,
        artifact_policy: %{"retain" => true},
        output_policy: %{"capture" => true},
        cleanup_grace_ms: Executor.default_cleanup_grace_ms()
      })

    {:ok, grant} = Executor.issue_grant({:host_policy, :allow}, job, now + 60_000)

    assert {:error, {:reconciliation_required, 1}} =
             Local.execute(fixture.executor, job, grant)

    refute File.exists?(Path.join(fixture.workspace, target))
  end

  defp await_run_finished_or_pending(attachment, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_run_finished_or_pending_until(attachment, deadline)
  end

  defp await_run_finished_or_pending_until(attachment, deadline) do
    case Loopex.next_event(attachment) do
      {:ok, %{kind: "run.finished"}} ->
        :finished

      {:ok, _event} ->
        await_run_finished_or_pending_until(attachment, deadline)

      _none ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(25)
          await_run_finished_or_pending_until(attachment, deadline)
        else
          :pending
        end
    end
  end

  # Concept: a refusal is only evidence if the contract entry exists to refuse.
  # `invoke_additive/3` reports an absent entry as an ordinary error, so a bare
  # `{:error, _}` here would be satisfied by the boundary simply not shipping.
  defp assert_refused(result) do
    assert {:error, reason} = result

    refute match?({:missing_additive_contract, _module, _function, _arity}, reason),
           "the contract entry is absent, so this refusal proves nothing: #{inspect(reason)}"

    reason
  end

  defp invoke_additive(module, function, arguments) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, length(arguments)) do
      apply(module, function, arguments)
    else
      {:error, {:missing_additive_contract, module, function, length(arguments)}}
    end
  end

  defp await_run_finished(attachment, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_run_finished_until(attachment, deadline)
  end

  defp await_run_finished_until(attachment, deadline) do
    case Loopex.next_event(attachment) do
      {:ok, %{kind: "run.finished"} = event} ->
        event

      {:ok, _event} ->
        await_run_finished_until(attachment, deadline)

      {:disconnected, cursor} ->
        flunk("prepared recovery attachment disconnected at cursor #{cursor}")

      {:error, reason} when reason != :empty ->
        flunk("prepared recovery event read failed: #{inspect(reason)}")

      _empty ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("prepared cancel recovery did not publish run.finished")
        else
          Process.sleep(5)
          await_run_finished_until(attachment, deadline)
        end
    end
  end
end
