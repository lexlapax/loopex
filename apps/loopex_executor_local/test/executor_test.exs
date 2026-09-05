defmodule Loopex.Executor.LocalTest do
  use ExUnit.Case, async: false

  alias Loopex.Executor
  alias Loopex.Executor.Local
  alias Loopex.Executor.Local.Ledger
  alias Loopex.Executor.Local.WorkspaceLease

  @oracle MapSet.new([
            :operation_id,
            :attempt,
            :canonical_request_digest,
            :tool_id,
            :tool_version,
            :effect_class,
            :workspace_lease,
            :executor_audience,
            :expiry,
            :fencing_token
          ])

  test "required grant bindings equal the independent contract oracle" do
    assert MapSet.new(Executor.required_grant_bindings()) == @oracle
  end

  test "each missing and wrong grant binding is refused before process start" do
    fixture = fixture("negative-bindings")
    on_exit(fn -> stop_fixture(fixture) end)
    {job, grant} = job_and_grant(fixture, "negative", "loopex.demo.write")

    # The refusal wears the tag that says it preceded the effect. That is the
    # half of this case's name a bare reason cannot carry: `refused before
    # process start` is a claim about a workspace, and the only party that can
    # make it is the executor that did or did not start something. A caller
    # reading these bare would be inferring it.
    for field <- Executor.required_grant_bindings() do
      assert {:error, {:refused_before_effect, {:missing_binding, ^field}}} =
               Local.execute(fixture.executor, job, Map.delete(grant, field))

      assert {:error, {:refused_before_effect, {:binding_mismatch, ^field}}} =
               Local.execute(fixture.executor, job, Map.put(grant, field, wrong(field, grant)))
    end

    assert %{dispatches: %{}} = Local.stats(fixture.executor)
    refute File.exists?(Path.join(fixture.workspace, "negative.txt"))
  end

  test "only an explicit host-policy allow decision can issue or widen a grant" do
    fixture = fixture("policy")
    on_exit(fn -> stop_fixture(fixture) end)
    {job, grant} = job_and_grant(fixture, "policy", "loopex.demo.write")
    expiry = System.system_time(:millisecond) + 60_000

    assert {:error, :host_policy_allow_required} =
             Executor.issue_grant({:model, :allow}, job, expiry)

    assert {:error, :host_policy_allow_required} =
             Executor.issue_grant({:client, :allow}, job, expiry)

    widened_job = %{job | tool_id: "loopex.demo.wait_write"}

    assert {:error, {:refused_before_effect, :canonical_job_request_mismatch}} =
             Local.execute(fixture.executor, widened_job, grant)

    assert grant.issued_by == :host_policy_allow
    assert MapSet.new(Map.keys(grant) -- [:issued_by, :policy_context]) == @oracle
    assert %{dispatches: %{}} = Local.stats(fixture.executor)
  end

  test "the executor recomputes the canonical JobRequest digest and the receipt retains verified origin identity" do
    fixture = fixture("digest")
    on_exit(fn -> stop_fixture(fixture) end)
    {job, grant} = job_and_grant(fixture, "digest", "loopex.demo.write")

    altered = %{job | canonical_request_digest: job.canonical_request_digest <> "00"}

    assert {:error, {:refused_before_effect, :canonical_job_request_mismatch}} =
             Local.execute(fixture.executor, altered, grant)

    assert %{dispatches: %{}} = Local.stats(fixture.executor)

    assert {:ok, receipt} = Local.execute(fixture.executor, job, grant)
    assert receipt.canonical_request_digest == job.canonical_request_digest
    assert receipt.operation_id == job.operation_id
    assert receipt.attempt == job.attempt
    assert receipt.session_id == job.session_id
    assert receipt.run_id == job.run_id
    assert receipt.turn_id == job.turn_id
    assert receipt.tool_call_id == job.tool_call_id
    assert receipt.session_epoch_at_dispatch == job.origin_session_epoch
    assert receipt.executor_epoch == job.origin_executor_epoch
    assert receipt.executor_identity == job.executor_identity
    assert receipt.fencing_token == job.fencing_token

    assert {:ok, ^receipt} = Local.receipt(fixture.executor, job.job_id)
  end

  test "the workspace lease is held for the job lifetime and loss kills owned work with retained evidence" do
    fixture = fixture("lease-loss")
    on_exit(fn -> stop_fixture(fixture) end)
    {job, grant} = job_and_grant(fixture, "lease-loss", "loopex.demo.wait_write")
    parent = self()

    task =
      Task.async(fn -> Local.execute(fixture.executor, job, grant, notify: parent) end)

    assert_receive {:executor_process_started, job_id, "loopex.demo.wait_write", ["PATH"]},
                   2_000

    assert job_id == job.job_id
    assert Process.alive?(fixture.lease)
    GenServer.stop(fixture.lease, :normal)

    assert {:ok, receipt} = Task.await(task, 5_000)
    assert receipt.outcome == :cancelled_workspace_lease_lost
    assert receipt.provider_credential_present == false
    assert {:ok, ^receipt} = Local.receipt(fixture.executor, job.job_id)
    refute File.exists?(Path.join(fixture.workspace, "lease-loss.txt"))
  end

  test "a starting job whose cancellation does not answer becomes unconfirmed" do
    table = :ets.new(:starting_cancel_test, [:set, :public])
    parent = self()

    worker =
      spawn(fn ->
        Process.put(:loopex_inflight_table, table)
        Process.put(:loopex_cleanup_grace_ms, 5)
        send(parent, {:starting_worker, self()})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:starting_worker, ^worker}, 1_000
    true = :ets.insert(table, {"starting-job", {:starting, worker}})

    assert Local.cancel(worker, "starting-job") == {:ok, :unconfirmed}

    monitor = Process.monitor(worker)
    send(worker, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 1_000
    :ets.delete(table)
  end

  test "the executor starts one credential-free OS tool that writes the expected workspace bytes and retains its receipt" do
    fixture = fixture("real-tool")
    on_exit(fn -> stop_fixture(fixture) end)
    {job, grant} = job_and_grant(fixture, "real-tool", "loopex.demo.write")

    previous = System.get_env("LOOPEX_PROVIDER_API_KEY")
    System.put_env("LOOPEX_PROVIDER_API_KEY", "must-not-reach-child")

    try do
      assert {:ok, receipt} = Local.execute(fixture.executor, job, grant, notify: self())
      assert_receive {:executor_process_started, job_id, "loopex.demo.write", ["PATH"]}
      assert job_id == job.job_id
      assert receipt.outcome == :completed
      assert receipt.child_environment_names == ["PATH"]
      assert receipt.provider_credential_present == false
      assert File.read!(Path.join(fixture.workspace, "real-tool.txt")) == "bytes-real-tool"
      assert {:ok, ^receipt} = Local.receipt(fixture.executor, job.job_id)

      assert {:ok, duplicate} = Local.execute(fixture.executor, job, grant)
      assert duplicate == receipt
      assert Local.stats(fixture.executor).dispatches[job.job_id] == 1
    after
      if previous,
        do: System.put_env("LOOPEX_PROVIDER_API_KEY", previous),
        else: System.delete_env("LOOPEX_PROVIDER_API_KEY")
    end
  end

  # Concept: a job this executor is still running has no receipt yet, and the
  # lookup says so rather than saying there is none.
  #
  # Technical depth: `:absent` is the answer that ends a recovered run
  # `outcome_unknown`, so a lookup that lands while the job is reserved here
  # answers `effect_in_flight`. The delaying tool keeps the job in flight long
  # enough for the lookup to land inside it, and the same lookup returns the
  # retained receipt once the job has settled.
  test "a receipt lookup for a job this executor still holds answers effect_in_flight" do
    fixture = fixture("in-flight-receipt")
    on_exit(fn -> stop_fixture(fixture) end)
    {job, grant} = job_and_grant(fixture, "in-flight", "loopex.demo.wait_write")

    running = Task.async(fn -> Local.execute(fixture.executor, job, grant) end)

    assert await_answer(fn -> Local.receipt(fixture.executor, job.job_id) end, 4_000) ==
             {:error, :effect_in_flight}

    assert {:ok, receipt} = Task.await(running, 30_000)
    assert {:ok, ^receipt} = Local.receipt(fixture.executor, job.job_id)
  end

  defp await_absent(lookup, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn -> lookup.() end)
    |> Enum.find_value(false, fn
      :absent -> true
      _other -> System.monotonic_time(:millisecond) > deadline && :expired
    end) == true
  end

  defp await_answer(lookup, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_answer_until(lookup, deadline)
  end

  defp await_answer_until(lookup, deadline) do
    case lookup.() do
      :absent ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          await_answer_until(lookup, deadline)
        else
          :absent
        end

      answer ->
        answer
    end
  end

  # Concept: a reservation belongs to the process that asked for it, and does
  # not outlive that process.
  #
  # Technical depth: the reserve call used to run under the default five-second
  # bound while the server could spend exactly five seconds waiting for the root
  # claim, so an expired caller left a reservation nothing released and the job
  # read as in flight forever. The caller is now monitored, and the call bound
  # outlives the claim wait. The first case kills a reserving caller; the second
  # holds the root claim for longer than the old bound and proves the caller is
  # answered, not exited.
  test "a reservation dies with the process that asked for it" do
    fixture = fixture("reservation-owner")
    on_exit(fn -> stop_fixture(fixture) end)
    {job, _grant} = job_and_grant(fixture, "owner", "loopex.demo.write")
    parent = self()

    reserver =
      spawn(fn ->
        send(parent, {:reserved, GenServer.call(fixture.executor, {:reserve, job})})
        receive do: (:release_me -> :ok)
      end)

    assert_receive {:reserved, {:ok, _placement}}, 5_000
    assert {:error, :effect_in_flight} = Local.receipt(fixture.executor, job.job_id)

    Process.exit(reserver, :kill)

    assert await_absent(fn -> Local.receipt(fixture.executor, job.job_id) end, 2_000),
           "the reservation outlived the process that asked for it"
  end

  test "a reserve blocked by a held claim is answered inside its own bound" do
    fixture = fixture("reservation-claim")
    on_exit(fn -> stop_fixture(fixture) end)
    {job, grant} = job_and_grant(fixture, "claim", "loopex.demo.write")
    {:ok, prepared} = Ledger.prepare(fixture.ledger, "executor-local", 5_000)

    holder =
      Task.async(fn ->
        Ledger.with_claim(prepared, fn -> Process.sleep(6_500) end)
      end)

    Process.sleep(100)
    started = System.monotonic_time(:millisecond)
    result = Local.execute(fixture.executor, job, grant)
    elapsed = System.monotonic_time(:millisecond) - started

    assert {:error, {:ledger_unavailable, :root_claim_held}} = result
    assert elapsed < 9_000, "the caller waited #{elapsed} ms instead of being answered"
    Task.await(holder, 10_000)
    assert :absent = Local.receipt(fixture.executor, job.job_id)
  end

  defp fixture(label) do
    root =
      Path.join(
        System.tmp_dir!(),
        "loopex-executor-#{label}-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "workspace")
    ledger = Path.join(root, "ledger")
    File.mkdir_p!(workspace)
    lease_id = "lease-#{label}"
    fence = 41

    {:ok, lease} =
      WorkspaceLease.start_link(id: lease_id, path: workspace, fencing_token: fence)

    {:ok, executor} =
      Local.start_link(
        identity: "executor-local",
        epoch: 7,
        fencing_token: fence,
        workspace_leases: %{lease_id => lease},
        ledger_root: ledger
      )

    %{
      root: root,
      workspace: workspace,
      ledger: ledger,
      lease_id: lease_id,
      fence: fence,
      lease: lease,
      executor: executor
    }
  end

  defp job_and_grant(fixture, label, tool_id) do
    {:ok, tool} = Local.tool(tool_id)
    now = System.system_time(:millisecond)

    arguments =
      %{"relative_path" => "#{label}.txt", "content" => "bytes-#{label}"}
      |> maybe_delay(tool_id)

    fields = %{
      protocol_version: 1,
      job_id: "job-#{label}",
      operation_id: "operation-#{label}",
      attempt: 1,
      session_id: "session-#{label}",
      run_id: "run-#{label}",
      turn_id: "turn-#{label}",
      tool_call_id: "tool-call-#{label}",
      origin_session_epoch: 3,
      origin_executor_epoch: 7,
      executor_identity: "executor-local",
      required_capabilities: ["workspace_write"],
      tool_id: tool.id,
      tool_version: tool.version,
      effect_class: tool.effect_class,
      validated_arguments: arguments,
      workspace_ref: "workspace-#{label}",
      workspace_lease: fixture.lease_id,
      run_deadline: now + 60_000,
      resource_budgets: %{"max_output_bytes" => 1_048_576},
      idempotency_class: "effectful",
      fencing_token: fixture.fence,
      artifact_policy: %{"retain" => true},
      output_policy: %{"capture" => true}
    }

    {:ok, job} = Executor.job(fields)
    {:ok, grant} = Executor.issue_grant({:host_policy, :allow}, job, now + 60_000)
    {job, grant}
  end

  defp maybe_delay(arguments, "loopex.demo.wait_write"), do: Map.put(arguments, "delay_ms", 5_000)
  defp maybe_delay(arguments, _tool), do: arguments

  defp wrong(:attempt, grant), do: grant.attempt + 1
  defp wrong(:expiry, _grant), do: System.system_time(:millisecond) - 1
  defp wrong(:fencing_token, grant), do: grant.fencing_token + 1

  defp wrong(field, grant) do
    case Map.get(grant, field) do
      value when is_binary(value) -> value <> "-wrong"
      _other -> "wrong"
    end
  end

  defp stop_fixture(fixture) do
    if Process.alive?(fixture.executor), do: GenServer.stop(fixture.executor)
    if Process.alive?(fixture.lease), do: GenServer.stop(fixture.lease)
    File.rm_rf!(fixture.root)
  end
end
