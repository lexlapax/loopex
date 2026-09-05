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

  # Concept: a pre-admission reservation belongs to the process that asked for
  # it, does not outlive that process, and does not yet claim an effect in flight.
  #
  # Technical depth: the reserve call used to run under the default five-second
  # bound while the server could spend exactly five seconds waiting for the root
  # claim, so an expired caller left a reservation nothing released and the job
  # read as in flight forever. The caller is now monitored, and the call bound
  # outlives the claim wait. The first case kills a reserving caller; the second
  # holds the root claim for longer than the old bound and proves the caller is
  # answered, not exited.
  test "a pre-admission reservation dies with the process that asked for it" do
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
    assert await_reservation_count(fixture.executor, job.job_id, 1, 2_000)
    assert :absent = Local.receipt(fixture.executor, job.job_id)

    Process.exit(reserver, :kill)

    assert await_reservation_count(fixture.executor, job.job_id, 0, 2_000),
           "the reservation outlived the process that asked for it"

    assert :absent = Local.receipt(fixture.executor, job.job_id)
  end

  test "same-job join reservations remain exact until each holder releases or dies" do
    # Concept: several callers may wait to join one durable operation. Finishing
    # one waiter says nothing about the other live waiters, and none of them
    # impersonates the operation's effect owner.
    #
    # Technical depth: the reservation table used one `job_id => caller` entry
    # but installed one monitor per call. A later same-job reservation overwrote
    # the caller, and either `release` or `DOWN` removed the job plus every monitor
    # carrying that ID. This case obtains three exact reservations, releases one,
    # kills another, and uses the surviving holder as the observable fact. Each
    # holder receives an opaque private reference, so cleanup can remove only the
    # reservation it owns without weakening the durable duplicate-effect fence.
    # The manually admitted entry has no effect owner in this instance, making
    # `effect_unresolved` the truthful receipt answer throughout.
    fixture = fixture("same-job-holders")
    on_exit(fn -> stop_fixture(fixture) end)
    {job, _grant} = job_and_grant(fixture, "same-job-holders", "loopex.demo.write")
    parent = self()

    assert {:ok, prepared} = Ledger.prepare(fixture.ledger, "executor-local", 5_000)

    assert :ok =
             Ledger.with_claim(prepared, fn ->
               Ledger.admit(
                 prepared,
                 Ledger.marker(job),
                 Ledger.open_entry(job, "executor-local")
               )
             end)

    holders =
      for label <- [:released, :dead, :survivor], into: %{} do
        pid =
          spawn(fn ->
            result = GenServer.call(fixture.executor, {:reserve, job})
            send(parent, {:holder_reserved, label, self(), result})
            reservation_holder(fixture.executor, job.job_id, label, result, parent)
          end)

        {label, pid}
      end

    reservations =
      for label <- [:released, :dead, :survivor], into: %{} do
        pid = Map.fetch!(holders, label)
        assert_receive {:holder_reserved, ^label, ^pid, {:ok, placement}}, 5_000
        {label, Map.fetch!(placement, :reservation_ref)}
      end

    assert reservations |> Map.values() |> MapSet.new() |> MapSet.size() == 3
    assert await_reservation_count(fixture.executor, job.job_id, 3, 2_000)
    assert {:error, :effect_unresolved} = Local.receipt(fixture.executor, job.job_id)

    send(holders.released, {:release, reservations.released})
    assert_receive {:holder_released, :released}, 1_000
    assert await_reservation_count(fixture.executor, job.job_id, 2, 2_000)
    assert {:error, :effect_unresolved} = Local.receipt(fixture.executor, job.job_id)

    Process.exit(holders.dead, :kill)

    assert await_reservation_count(fixture.executor, job.job_id, 1, 2_000),
           "the dead holder's reservation was not removed independently"

    assert {:error, :effect_unresolved} = Local.receipt(fixture.executor, job.job_id)

    send(holders.survivor, {:release, reservations.survivor})
    assert_receive {:holder_released, :survivor}, 1_000
    assert await_reservation_count(fixture.executor, job.job_id, 0, 2_000)

    assert Local.receipt(fixture.executor, job.job_id) == {:error, :effect_unresolved},
           "the open effect did not become unresolved after its last exact holder released"
  end

  test "a live join waiter does not impersonate an effect owner after that owner dies" do
    # Concept: a caller waiting to join one admitted operation is not evidence
    # that this executor still owns the effect. If the actual effect owner dies,
    # the durable open entry becomes unresolved and keeps the root quarantined
    # even while the join waiter remains alive.
    #
    # Technical depth: every caller first receives a reservation token, but only
    # the token whose `admit/2` publishes the marker and open entry may become an
    # effect owner. This case holds that owner inside a delayed real tool, keeps
    # one same-job joiner polling, and exercises release and `DOWN` on two more
    # join-only tokens before killing the owner. Counting every reservation as
    # effectful then lies twice: receipt lookup reports `effect_in_flight`, and
    # reconciliation excludes the open entry so an unrelated effect is admitted.
    # Exact owner state must instead disappear on that token's `DOWN` without
    # removing the polling joiner's independent reservation.
    fixture = fixture("dead-owner-live-joiner")
    on_exit(fn -> stop_fixture(fixture) end)
    {job, grant} = job_and_grant(fixture, "dead-owner-live-joiner", "loopex.demo.wait_write")
    parent = self()

    owner =
      Task.async(fn -> Local.execute(fixture.executor, job, grant, notify: parent) end)

    assert_receive {:executor_process_started, job_id, "loopex.demo.wait_write", ["PATH"]},
                   5_000

    assert job_id == job.job_id

    joiner = Task.async(fn -> Local.execute(fixture.executor, job, grant) end)

    released_joiner =
      spawn(fn ->
        result = GenServer.call(fixture.executor, {:reserve, job})
        send(parent, {:holder_reserved, :owner_test_release, self(), result})

        reservation_holder(
          fixture.executor,
          job.job_id,
          :owner_test_release,
          result,
          parent
        )
      end)

    dead_joiner =
      spawn(fn ->
        result = GenServer.call(fixture.executor, {:reserve, job})
        send(parent, {:holder_reserved, :owner_test_dead, self(), result})
        reservation_holder(fixture.executor, job.job_id, :owner_test_dead, result, parent)
      end)

    assert_receive {:holder_reserved, :owner_test_release, ^released_joiner,
                    {:ok, released_placement}},
                   5_000

    released_ref = Map.fetch!(released_placement, :reservation_ref)

    assert_receive {:holder_reserved, :owner_test_dead, ^dead_joiner, {:ok, _dead_placement}},
                   5_000

    try do
      assert await_reservation_count(fixture.executor, job.job_id, 4, 2_000),
             "the same-job joiners never obtained independent reservations"

      send(released_joiner, {:release, released_ref})
      assert_receive {:holder_released, :owner_test_release}, 1_000

      assert await_reservation_count(fixture.executor, job.job_id, 3, 2_000),
             "releasing one joiner erased another same-job holder"

      assert {:error, :effect_in_flight} = Local.receipt(fixture.executor, job.job_id)

      Process.exit(dead_joiner, :kill)

      assert await_reservation_count(fixture.executor, job.job_id, 2, 2_000),
             "a joiner's DOWN erased another same-job holder"

      assert {:error, :effect_in_flight} = Local.receipt(fixture.executor, job.job_id)

      _owner_result = Task.shutdown(owner, :brutal_kill)

      assert await_reservation_count(fixture.executor, job.job_id, 1, 2_000),
             "the dead effect owner's reservation was not removed independently"

      assert Process.alive?(joiner.pid), "the same-job joiner did not remain live"

      {unrelated, unrelated_grant} =
        job_and_grant(fixture, "after-dead-owner", "loopex.demo.write")

      unrelated_result = Local.execute(fixture.executor, unrelated, unrelated_grant)
      receipt_result = Local.receipt(fixture.executor, job.job_id)

      assert unrelated_result == {:error, {:reconciliation_required, 1}},
             "a join-only reservation hid the dead owner's unresolved open authority"

      assert receipt_result == {:error, :effect_unresolved},
             "the live joiner was reported as the dead operation's effect owner"

      assert {:ok, prepared} = Ledger.prepare(fixture.ledger, "executor-local", 5_000)
      assert Ledger.open?(prepared, job.job_id)
    after
      if Process.alive?(owner.pid), do: Task.shutdown(owner, :brutal_kill)
      if Process.alive?(joiner.pid), do: Task.shutdown(joiner, :brutal_kill)
      if Process.alive?(released_joiner), do: Process.exit(released_joiner, :kill)
      if Process.alive?(dead_joiner), do: Process.exit(dead_joiner, :kill)
    end
  end

  test "a reserve blocked by a held claim is answered inside its own bound" do
    fixture = fixture("reservation-claim")
    on_exit(fn -> stop_fixture(fixture) end)
    {job, grant} = job_and_grant(fixture, "claim", "loopex.demo.write")
    {:ok, prepared} = Ledger.prepare(fixture.ledger, "executor-local", 5_000)
    parent = self()

    holder =
      Task.async(fn ->
        Ledger.with_claim(prepared, fn ->
          send(parent, :reservation_claim_held)
          Process.sleep(6_500)
        end)
      end)

    assert_receive :reservation_claim_held, 1_000
    started = System.monotonic_time(:millisecond)
    result = Local.execute(fixture.executor, job, grant)
    elapsed = System.monotonic_time(:millisecond) - started

    assert {:error, {:ledger_unavailable, :root_claim_held}} = result
    assert elapsed < 9_000, "the caller waited #{elapsed} ms instead of being answered"

    assert elapsed >= 4_500,
           "the server answered after #{elapsed} ms without spending its claim wait"

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

  defp reservation_holder(executor, job_id, label, {:ok, _placement}, parent) do
    receive do
      {:release, reservation_ref} ->
        GenServer.cast(executor, {:release, job_id, reservation_ref})
        _barrier = GenServer.call(executor, :stats)
        send(parent, {:holder_released, label})
    end
  end

  defp reservation_holder(_executor, _job_id, _label, _answer, _parent), do: :ok

  defp await_reservation_count(executor, job_id, expected, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_reservation_count_until(executor, job_id, expected, deadline)
  end

  defp await_reservation_count_until(executor, job_id, expected, deadline) do
    holders = executor |> :sys.get_state() |> Map.fetch!(:reserved) |> Map.get(job_id)

    count = if match?(%MapSet{}, holders), do: MapSet.size(holders), else: 0

    if count == expected do
      true
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(5)
        await_reservation_count_until(executor, job_id, expected, deadline)
      else
        false
      end
    end
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
