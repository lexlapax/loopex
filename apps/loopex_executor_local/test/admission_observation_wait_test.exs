defmodule Loopex.Executor.Local.AdmissionObservationWaitTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Loopex.Executor
  alias Loopex.Executor.Local
  alias Loopex.Executor.Local.WorkspaceLease

  @identity "admission-observation"
  @epoch 3
  @fence 19

  # Concept: waiting for a reservation does not abandon the caller's request.
  #
  # Technical depth: the exact public caller's reservation is positively queued
  # in the suspended real Local. Keep that established hold beyond the former
  # ten-second observation timeout, release it, and require the actual effect
  # and durable receipt. The hold schedules the old timeout boundary; elapsed
  # time or silence is not the result. This does not simulate slow filesystem IO.
  test "a queued public execute waits for its actual reservation result" do
    fixture = fixture()
    {request, grant} = request(fixture, "queued-reservation")
    assert :erlang.suspend_process(fixture.local)

    try do
      {caller, monitor} = execute(fixture.local, request, grant)

      assert :ok =
               await_message(fixture.local, fn
                 {:"$gen_call", {^caller, _tag}, {:reserve, ^request}} -> true
                 _other -> false
               end)

      assert :ok =
               await_observation(fn -> Process.info(caller, :status) == {:status, :waiting} end)

      Process.sleep(10_001)
      assert :erlang.resume_process(fixture.local)
      assert_completed(fixture, request, await_result(caller, monitor))
    after
      resume_if_suspended(fixture.local)
    end
  end

  # Concept: a delayed permit decision still returns its actual answer.
  #
  # Technical depth: the existing paired-clock callback holds the real permit
  # handler before publication. Receive tracing identifies the exact public
  # caller, request, and grant first. Both samples return actual current clocks
  # when released; no deadline or owner fence is replaced. This is a controlled
  # handler delay, not a reproduction of a slow disk or a timing-only verdict.
  test "a public execute waits for a held permit handler and its real publication" do
    observer = self()
    correlation = make_ref()
    held = :atomics.new(1, [])

    clock = fn ->
      if :atomics.compare_exchange(held, 1, 0, 1) == :ok do
        send(observer, {correlation, :clock_held, self()})

        receive do
          {^correlation, :release_clock} -> :ok
        end
      end

      {System.system_time(:millisecond), System.monotonic_time(:millisecond)}
    end

    fixture = fixture(clock_provider: clock)
    {request, grant} = request(fixture, "held-permit")
    local = fixture.local
    assert :erlang.trace(local, true, [:receive, {:tracer, observer}]) == 1

    try do
      {caller, monitor} = execute(local, request, grant)

      assert_receive {:trace, ^local, :receive,
                      {:"$gen_call", {^caller, _tag}, {:permit, ^request, ^grant, reservation}}},
                     1_000

      assert is_reference(reservation)
      assert_receive {^correlation, :clock_held, ^local}, 1_000
      assert :erlang.trace(local, false, [:receive]) == 1

      assert :ok =
               await_observation(fn -> Process.info(caller, :status) == {:status, :waiting} end)

      Process.sleep(15_001)
      send(local, {correlation, :release_clock})
      assert_completed(fixture, request, await_result(caller, monitor))
    after
      if Process.alive?(local) do
        :erlang.trace(local, false, [:receive])
        send(local, {correlation, :release_clock})
      end
    end
  end

  defp fixture(options \\ []) do
    root =
      Path.join(
        System.tmp_dir!(),
        "loopex-admission-observation-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    lease_id = "lease-#{System.unique_integer([:positive])}"

    lease =
      start_supervised!({WorkspaceLease, id: lease_id, path: workspace, fencing_token: @fence})

    local =
      start_supervised!(
        {Local,
         [
           identity: @identity,
           epoch: @epoch,
           fencing_token: @fence,
           workspace_leases: %{lease_id => lease},
           ledger_root: Path.join(root, "ledger")
         ] ++ options}
      )

    %{local: local, workspace: workspace, lease_id: lease_id}
  end

  defp request(fixture, id) do
    assert {:ok, request} =
             Executor.job(%{
               protocol_version: 1,
               job_id: id,
               operation_id: "operation-#{id}",
               attempt: 1,
               session_id: "observation-session",
               run_id: "observation-run",
               turn_id: "observation-turn",
               tool_call_id: "call-#{id}",
               origin_session_epoch: 1,
               origin_executor_epoch: @epoch,
               executor_identity: @identity,
               required_capabilities: ["workspace_write"],
               tool_id: "loopex.write",
               tool_version: "1.0.0",
               effect_class: "workspace_write",
               validated_arguments: %{"path" => "#{id}.txt", "content" => id},
               workspace_ref: "observation-workspace",
               workspace_lease: fixture.lease_id,
               run_deadline: System.system_time(:millisecond) + 30_000,
               resource_budgets: %{"max_output_bytes" => 65_536},
               idempotency_class: "safe_retry",
               fencing_token: @fence,
               artifact_policy: %{"retain" => true},
               output_policy: %{"capture" => true}
             })

    assert {:ok, grant} =
             Executor.issue_grant({:host_policy, :allow}, request, request.run_deadline)

    {request, grant}
  end

  defp execute(local, request, grant) do
    observer = self()

    {caller, monitor} =
      spawn_monitor(fn ->
        send(observer, {:execute_result, self(), Local.execute(local, request, grant)})
      end)

    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
    {caller, monitor}
  end

  defp await_result(caller, monitor) do
    receive do
      {:execute_result, ^caller, result} ->
        assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}, 1_000
        result

      {:DOWN, ^monitor, :process, ^caller, reason} ->
        flunk(
          "the public execute caller exited instead of returning its decision: #{inspect(reason)}"
        )
    after
      5_000 -> flunk("the released public execute returned no actual decision")
    end
  end

  defp assert_completed(fixture, request, result) do
    assert {:ok, receipt} = result
    assert receipt.job_id == request.job_id
    assert receipt.outcome == :completed
    assert receipt.cleanup_confirmation == :confirmed
    assert File.read!(Path.join(fixture.workspace, "#{request.job_id}.txt")) == request.job_id
    assert Local.receipt(fixture.local, request.job_id) == result
  end

  defp await_message(pid, predicate) do
    await_observation(fn ->
      {:messages, messages} = Process.info(pid, :messages)
      Enum.any?(messages, predicate)
    end)
  end

  defp await_observation(check, deadline \\ System.monotonic_time(:millisecond) + 1_000) do
    cond do
      check.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :observation_unavailable}

      true ->
        Process.sleep(5)
        await_observation(check, deadline)
    end
  end

  defp resume_if_suspended(pid) do
    if Process.alive?(pid) and Process.info(pid, :status) == {:status, :suspended},
      do: :erlang.resume_process(pid)
  end
end
