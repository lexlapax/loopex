Code.require_file("support/runtime_fixture.ex", __DIR__)

defmodule Loopex.ReferenceClient.ConfiguredRecoveryContractTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Loopex.Executor.Local
  alias Loopex.ReferenceClient
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

    terminal = await_run_finished(attachment, 10_000)
    assert terminal["outcome"] == "completed"
    assert terminal["cleanup_grace_ms"] == cleanup_grace_ms
    assert retained.cleanup_grace_ms == cleanup_grace_ms
    assert {:ok, ^retained} = Local.receipt(restarted.executor, retained.job_id)

    refute_receive {:model_request, _request}, 200
    assert Local.stats(restarted.executor).dispatches == %{}
    assert File.read!(effect_path) == content
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

      {:error, reason} ->
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
