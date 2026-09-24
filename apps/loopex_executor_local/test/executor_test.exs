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

  test "a malformed job is refused without reserving an empty identity" do
    fixture = fixture("malformed-job")
    on_exit(fn -> stop_fixture(fixture) end)

    refusal = {:error, {:refused_before_effect, :canonical_job_request_mismatch}}

    assert ^refusal = Local.execute(fixture.executor, %{}, %{})

    # The serialized boundary itself refuses the missing identity. Observing it
    # directly makes the no-reservation half non-vacuous: a path that briefly
    # reserves under "" and releases after the public call would otherwise look
    # identical once `execute/3` returns.
    assert ^refusal = GenServer.call(fixture.executor, {:reserve, %{}})

    assert Process.alive?(fixture.executor)
    assert %{dispatches: %{}} = Local.stats(fixture.executor)
    refute Map.has_key?(:sys.get_state(fixture.executor).reserved, "")
    assert Local.receipt(fixture.executor, "") == :absent
  end

  test "an oversized job identity is refused before ledger lookup or reservation" do
    fixture = fixture("oversized-job-identity")
    on_exit(fn -> stop_fixture(fixture) end)

    job_id = String.duplicate("x", 8_193)
    invalid_job = %{job_id: job_id}
    refusal = {:error, {:refused_before_effect, :canonical_job_request_mismatch}}

    assert ^refusal = Local.execute(fixture.executor, invalid_job, %{})

    # The public answer alone cannot distinguish this early refusal from a
    # reservation followed by full permit validation. The serialized boundary
    # must itself refuse the identifier before it reaches ledger path/key work.
    assert ^refusal = GenServer.call(fixture.executor, {:reserve, invalid_job})

    assert Process.alive?(fixture.executor)
    assert %{dispatches: %{}} = Local.stats(fixture.executor)
    refute Map.has_key?(:sys.get_state(fixture.executor).reserved, job_id)
  end

  test "each missing and wrong grant binding is refused before process start" do
    fixture = fixture("negative-bindings")
    on_exit(fn -> stop_fixture(fixture) end)

    # The refusal wears the tag that says it preceded the effect. That is the
    # half of this case's name a bare reason cannot carry: `refused before
    # process start` is a claim about a workspace, and the only party that can
    # make it is the executor that did or did not start something. A caller
    # reading these bare would be inferring it.
    for field <- Executor.required_grant_bindings() do
      {missing_job, missing_grant} =
        job_and_grant(fixture, "negative-missing-#{field}", "loopex.demo.write")

      assert {:error, {:refused_before_effect, {:missing_binding, ^field}}} =
               Local.execute(fixture.executor, missing_job, Map.delete(missing_grant, field))

      {wrong_job, wrong_grant} =
        job_and_grant(fixture, "negative-wrong-#{field}", "loopex.demo.write")

      assert {:error, {:refused_before_effect, {:binding_mismatch, ^field}}} =
               Local.execute(
                 fixture.executor,
                 wrong_job,
                 Map.put(wrong_grant, field, wrong(field, wrong_grant))
               )
    end

    assert %{dispatches: %{}} = Local.stats(fixture.executor)
    assert File.ls!(fixture.workspace) == []
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

    # The attempt-local deadline is outside the digest, but it is still a
    # required bounded job fact. Missing, malformed, and run-widening values all
    # refuse at the same serialized boundary before a reservation or effect can
    # exist. Without a positive dispatch-local wall ceiling, equality to the run
    # deadline is independently reproducible too.
    bounded_fields =
      job
      |> Map.from_struct()
      |> Map.drop([:canonical_request_bytes, :canonical_request_digest, :effective_job_deadline])
      |> Map.put(:resource_budgets, %{
        "max_output_bytes" => 1_048_576,
        "max_wall_time_ms" => 1_000
      })

    assert {:ok, bounded_job} = Executor.job(bounded_fields)
    assert :ok = Executor.validate_job(bounded_job)

    assert {:ok, bounded_grant} =
             Executor.issue_grant({:host_policy, :allow}, bounded_job, grant.expiry)

    invalid_deadlines = [
      Map.delete(bounded_job, :effective_job_deadline),
      %{bounded_job | effective_job_deadline: "later"},
      %{bounded_job | effective_job_deadline: bounded_job.run_deadline + 1}
    ]

    for malformed <- invalid_deadlines do
      assert {:error, :canonical_job_request_mismatch} = Executor.validate_job(malformed)

      assert {:error, {:refused_before_effect, :canonical_job_request_mismatch}} =
               Local.execute(fixture.executor, malformed, bounded_grant)
    end

    shortened_without_ceiling = %{job | effective_job_deadline: job.run_deadline - 1}

    assert {:error, :canonical_job_request_mismatch} =
             Executor.validate_job(shortened_without_ceiling)

    assert {:error, {:refused_before_effect, :canonical_job_request_mismatch}} =
             Local.execute(fixture.executor, shortened_without_ceiling, grant)

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
    # The demonstration's delay is declared per job. Two seconds is the whole
    # horizon this case waits out below, and it still starts well before the
    # lease is stopped, so shortening it changes how long the case takes and
    # nothing about what it observes.
    {default_job, default_grant} =
      job_and_grant(fixture, "lease-loss", "loopex.demo.wait_write", %{
        "relative_path" => "lease-loss.txt",
        "content" => "bytes-lease-loss",
        "delay_ms" => 2_000
      })

    # Concept: lease loss ends this real job under its own committed period.
    # Technical depth: the unchanged five-second observation must cover both
    # cleanup and retention. The default permits five seconds plus 1,250ms of
    # retention, so this case instead commits 1,000ms plus 250ms. Rebuild the
    # request and grant; changing the executor's startup default cannot change
    # an already-digested job. RUN-sent is a post-permit boundary, not a witness
    # that the demo interpreter has reached its sleep.
    assert {:ok, job} =
             default_job
             |> Map.from_struct()
             |> Map.put(:cleanup_grace_ms, 1_000)
             |> Executor.job()

    assert {:ok, grant} =
             Executor.issue_grant({:host_policy, :allow}, job, default_grant.expiry)

    assert job.cleanup_grace_ms == 1_000
    parent = self()

    task =
      Task.async(fn -> Local.execute(fixture.executor, job, grant, notify: parent) end)

    assert_receive {:executor_process_started, job_id, "loopex.demo.wait_write", ["PATH"]},
                   2_000

    assert job_id == job.job_id
    assert Process.alive?(fixture.lease)
    GenServer.stop(fixture.lease, :normal)

    assert {:ok, receipt} = Task.await(task, 5_000)

    # The lease ended before the receipt existed, so the effect is unproven even
    # though the owned process group was positively stopped. Those are separate
    # facts: losing authority cannot erase the cleanup proof.
    assert receipt.outcome == :outcome_unknown

    assert receipt.cleanup_confirmation == :confirmed,
           "lease-loss cleanup was not proved: #{inspect(receipt)}"

    assert receipt.provider_credential_present == false
    assert receipt.cleanup_grace_ms == 1_000
    assert receipt.receipt_retention_bound_ms == 250
    assert receipt.canonical_request_digest == job.canonical_request_digest

    # Confirmed cleanup permits the open authority to be removed, so the durable
    # receipt is also the final recovery answer.
    receipt_name =
      (:crypto.hash(:sha256, job.job_id) |> Base.encode16(case: :lower)) <> ".receipt"

    assert {:ok, retained_bytes} = File.read(Path.join(fixture.ledger, receipt_name))
    assert :erlang.binary_to_term(retained_bytes, [:safe]) == receipt
    assert {:ok, ^receipt} = Local.receipt(fixture.executor, job.job_id)

    # The demo waits two seconds before writing. Waiting beyond that declared
    # horizon proves the owned effect was actually stopped rather than merely
    # checking before a surviving child had time to act.
    Process.sleep(2_500)

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

    true =
      :ets.insert(table, [
        {"starting-job", {:starting, worker}},
        {{:loopex_process_authority, "starting-job"}, worker, 5}
      ])

    assert Local.cancel(worker, "starting-job") == {:ok, :unconfirmed}

    monitor = Process.monitor(worker)
    send(worker, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 1_000
    :ets.delete(table)
  end

  test "cancellation reaches the live launch owner with the job's committed period" do
    # Concept: the process that captured the group remains the only authority
    # allowed to signal it; a numeric observation in another process is not.
    #
    # Technical depth: the primary row deliberately carries a group that has no
    # relation to the worker. A cancellation implementation that signals the
    # number directly can still answer `cleaned` when that group is absent, so the
    # decisive assertion is that the live owner receives the caller's exact
    # cleanup episode with the period published for this job rather than the
    # executor's default. Carrying the absolute instant matters too: queueing at
    # the owner spends this one episode and cannot open another full period.
    table = :ets.new(:owned_cancel_test, [:set, :public])
    parent = self()
    job_id = "owned-cancel-job"
    grace = 17
    probe = "/fixture/process-probe"

    worker =
      spawn(fn ->
        Process.put(:loopex_inflight_table, table)
        Process.put(:loopex_process_probe, probe)
        send(parent, {:owned_cancel_worker, self()})

        receive do
          {:loopex_cancel_pending, token, from, {received_until, received_grace, received_probe}} ->
            send(
              parent,
              {:owned_cancel_received, self(), received_until, received_grace, received_probe}
            )

            send(from, {:loopex_cancel_result, token, {:ok, :cleaned}})
        end
      end)

    assert_receive {:owned_cancel_worker, ^worker}, 1_000

    true =
      :ets.insert(table, [
        {job_id, 4_294_967_000},
        {{:loopex_process_authority, job_id}, worker, grace}
      ])

    started = System.monotonic_time(:millisecond)
    monitor = Process.monitor(worker)
    assert Local.cancel(worker, job_id) == {:ok, :cleaned}

    assert_receive {:owned_cancel_received, ^worker, received_until, ^grace, ^probe}, 1_000
    assert received_until >= started + grace
    assert received_until <= System.monotonic_time(:millisecond) + grace
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 1_000

    source = File.read!(Path.expand("../lib/executor.ex", __DIR__))

    [cancel_branch] =
      Regex.run(
        ~r/\{:loopex_cancel_pending, token, caller, episode\} ->(.*?)\{:DOWN, \^owner_monitor/s,
        source,
        capture: :all_but_first
      )

    assert cancel_branch =~ "finish_guarded_output("
    assert cancel_branch =~ "episode,"
    assert cancel_branch =~ ":terminate"
    refute cancel_branch =~ "cancellation_episode("
    :ets.delete(table)
  end

  test "cancellation keeps waiting past the episode instant" do
    # Concept: the caller of `cancel/2` keeps listening after the episode's
    # instant, because the answer it waits for is sent after that.
    #
    # Technical depth: this proves only that the caller waits past the
    # instant. The stand-in owner holds the real caller's exact episode, waits
    # until the instant has passed on the same monotonic clock, gives the
    # caller up to 300 ms more to stop waiting, and then answers `cleaned`. A
    # caller that stops at the instant has returned `unconfirmed` by then; one
    # that keeps waiting returns the answer.
    {worker, job_id, table} =
      stand_in_owner("late-answer-cancel-job", 40, fn token, reply_to, {until, _grace, _probe} ->
        requester =
          receive do
            {:requester, pid} -> pid
          end

        wait_past(until)
        requester_monitor = Process.monitor(requester)

        receive do
          {:DOWN, ^requester_monitor, :process, ^requester, _reason} -> :ok
        after
          300 -> Process.demonitor(requester_monitor, [:flush])
        end

        send(reply_to, {:loopex_cancel_result, token, {:ok, :cleaned}})
      end)

    cancelling = Task.async(fn -> Local.cancel(worker, job_id) end)
    send(worker, {:requester, cancelling.pid})
    assert Task.await(cancelling, 5_000) == {:ok, :cleaned}
    :ets.delete(table)
  end

  test "the reply margin is the retention allowance plus a second, capped inside Core's bound" do
    # Concept: how long past its episode a cancelling caller waits follows the
    # job's own settlement bound, and never lets the whole wait reach the
    # bound Core observes the cancellation for.
    #
    # Technical depth: the margin is `min(receipt_retention_ms + 1_000,
    # executor_observe_ms - grace - 250)` for the job's period. A stand-in
    # owner reports the exact episode instant it was handed and answers at
    # once; the caller's traced wait shows the instant it waits until, and the
    # difference is the margin. 2,000 and 6,000 ms take the uncapped branch;
    # 7,500 ms is capped at `9_750 - grace`, and 16,000 ms at 1,750 ms.
    for {grace, margin} <- [{2_000, 1_500}, {6_000, 2_500}, {7_500, 2_250}, {16_000, 1_750}] do
      parent = self()

      {worker, job_id, table} =
        stand_in_owner("margin-#{grace}", grace, fn token, reply_to, {until, _grace, _probe} ->
          send(parent, {:instant, until})
          send(reply_to, {:loopex_cancel_result, token, {:ok, :cleaned}})
        end)

      events =
        trace_local_calls([await_cancel_result: 4], fn ->
          assert Local.cancel(worker, job_id) == {:ok, :cleaned}
        end)

      assert_receive {:instant, instant}, 1_000
      [{:await_cancel_result, [_watched, _monitor, _token, waits_until]} | _] = events
      assert waits_until - instant == margin, "grace #{grace} waited #{waits_until - instant}ms"
      :ets.delete(table)
    end
  end

  test "a cancellation that stopped waiting receives nothing sent to it afterwards" do
    # Concept: once `cancel/2` has returned, its caller's mailbox is its own
    # again: a hand-off or answer that arrives late never lands in it.
    #
    # Technical depth: the requests carry a process alias as their reply
    # target, and `cancel/2` removes it before returning. The stand-in owner
    # holds this case's request without answering until the case's own
    # `cancel/2` has timed out and returned `unconfirmed`, then sends a
    # hand-off and an answer to the reply target it was given and reports that
    # it has. Both come from the stand-in before its report, so a pid target
    # would have them queued here ahead of it; the removed alias has the VM
    # drop them.
    parent = self()

    {worker, job_id, table} =
      stand_in_owner("late-reply-cancel-job", 5, fn token, reply_to, _episode ->
        receive do
          :send_late -> :ok
        end

        send(reply_to, {:loopex_cancel_handoff, token, parent})
        send(reply_to, {:loopex_cancel_result, token, {:ok, :cleaned}})
        send(parent, :sent_late)
      end)

    assert Local.cancel(worker, job_id) == {:ok, :unconfirmed}
    send(worker, :send_late)
    assert_receive :sent_late, 2_000
    refute_received {:loopex_cancel_handoff, _token, _settler}
    refute_received {:loopex_cancel_result, _token, _answer}
    :ets.delete(table)
  end

  test "forced KILL cleanup is confirmed by exactly its three positive facts" do
    # Concept: a forced cancellation is confirmed when KILL went over the live
    # Port, the Port then exited nonzero, and a complete process table shows the
    # captured group empty -- and by nothing less.
    #
    # Technical depth: the real-process case cannot choose which of these a
    # loaded host delivers inside the period, so the rule is proved here on
    # supplied facts through the seam that composes production's own private
    # functions. The table is well formed and witnessed by its own probe row;
    # only the rows of the captured group differ.
    group = 900
    witness = 700
    empty = {:answered, "#{witness} #{witness}\n800 800\n", 0, witness}
    occupied = {:answered, "#{witness} #{witness}\n901 #{group}\n", 0, witness}

    all = %{kill_sent: true, port_exit_status: 137, table_answer: empty, group: group}

    assert Local.forced_kill_confirmed?(all),
           "KILL over the live Port, a nonzero Port exit and an empty table did not confirm"

    refute Local.forced_kill_confirmed?(%{all | kill_sent: false}),
           "cleanup was confirmed although KILL was never sent over the live Port"

    refute Local.forced_kill_confirmed?(%{all | port_exit_status: 0}),
           "cleanup was confirmed although the killed guard's Port exited zero"

    refute Local.forced_kill_confirmed?(%{all | port_exit_status: nil}),
           "cleanup was confirmed although the Port never reported an exit"

    refute Local.forced_kill_confirmed?(%{all | table_answer: occupied}),
           "cleanup was confirmed although the table still held a group member"

    refute Local.forced_kill_confirmed?(%{all | table_answer: :no_answer}),
           "cleanup was confirmed although the probe never answered"
  end

  test "a cleanup probe and the confirmation of its helper stay inside the owner's instant" do
    # Concept: an owner's probe spends only what remains of the owner's episode,
    # so the owner's verdict exists by the episode's instant; and a probe with
    # too little time does not start.
    #
    # Technical depth: this is observed through call tracing of the helper's
    # private steps rather than wall time, so it holds on any host. The owner's
    # instant is the one handed to `guarded_answer_until/3` -- production owner
    # sites pass their episode's `until` there unchanged, which the source check
    # below pins, and `answer_within/3` passes the instant it opens for its
    # bound. The helper never answers, so its answer wait expires and it is
    # abandoned. Its episode must end at exactly the owner's instant rather than
    # at a rebuilt `now + remaining`; every instant its KILL confirmation is
    # given must be at or before the owner's instant; and the answer must stop
    # strictly before it so the confirmation has time. A bound of one
    # millisecond cannot hold both shares, so no launcher opens.
    events =
      trace_local_calls(
        [guarded_answer_until: 3, collect_answer: 4, await_helper_guard_exit: 5],
        fn ->
          assert Local.answer_within("/bin/sh", ["-c", "sleep 30"], 300) == :no_answer
        end
      )

    [{:guarded_answer_until, [_program, _arguments, owner_until]}] =
      Enum.filter(events, &match?({:guarded_answer_until, _}, &1))

    [{:collect_answer, [_port, _collector, {answer_stop, {helper_until, _, nil}}, _limit]} | _] =
      Enum.filter(events, &match?({:collect_answer, _}, &1))

    assert helper_until == owner_until,
           "the helper's episode ends at #{helper_until}, not at the owner's instant #{owner_until}"

    confirmation_stops =
      for {:await_helper_guard_exit, [_port, _collector, stop, _limit, _overflow]} <- events,
          uniq: true,
          do: stop

    assert confirmation_stops != [], "the abandoned helper's KILL was never confirmed"

    assert Enum.all?(confirmation_stops, &(&1 <= owner_until)),
           "the helper's KILL confirmation was given until #{inspect(confirmation_stops)}, " <>
             "past the owner's instant #{owner_until}"

    assert answer_stop < owner_until,
           "the helper's answer took the whole bound and left nothing for its confirmation"

    opened =
      trace_local_calls([open_launcher: 4], fn ->
        assert Local.answer_within("/bin/sh", ["-c", "printf answered"], 1) == :no_answer
      end)

    assert opened == [], "a probe with one millisecond left still launched a helper"

    source = File.read!(Path.expand("../lib/executor.ex", __DIR__))

    assert source =~ "answer = process_table_until(probe, until)",
           "the quiescence probe no longer receives its owner's episode instant"

    assert source =~ "confirm_released_group_terminated(group, probe, until) ->",
           "the post-KILL probe no longer receives its owner's episode instant"
  end

  test "a command worker that exits before its effect with nobody to settle hands nothing on" do
    # Concept: a worker that ends before its process begins never answers a
    # cancellation, and hands one on only to an execute caller that will
    # settle the job; with none left, the request is left to its caller's
    # `DOWN`, which `cancel/2` answers `unconfirmed`.
    #
    # Technical depth: three exits leave the start handshake without running
    # the effect: the execute caller's death, the Local authority's death, and
    # a run signal consumed after that authority has died. The stand-in
    # authority owns the in-flight table, as the executor does, so its death
    # takes the table the hand-off claim is taken in; the caller's death here
    # is observed directly by the worker. In none of them is the request
    # answered or handed on. The worker is
    # suspended, the triggering signal is queued ahead of a request, and the
    # worker is resumed; mailbox order fixes which is matched first.
    for exit <- [:caller_down, :guard_down, :run_with_dead_guard] do
      {worker, _table, tag, _job_id, caller, guard} = pre_run_worker("pre-run-exit-#{exit}", exit)
      worker_monitor = Process.monitor(worker)
      assert :erlang.suspend_process(worker)

      case exit do
        :caller_down ->
          Process.exit(caller, :kill)
          assert {:ok, :ready} = await_mailbox(worker, &down_from?(&1, caller))

        :guard_down ->
          Process.exit(guard, :kill)
          assert {:ok, :ready} = await_mailbox(worker, &down_from?(&1, guard))

        :run_with_dead_guard ->
          send(worker, {tag, :run})
          Process.exit(guard, :kill)
          assert {:ok, :ready} = await_mailbox(worker, &down_from?(&1, guard))
      end

      token = queue_cancellation(worker)
      assert :erlang.resume_process(worker)
      assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :normal}, 2_000
      refute_received {:loopex_cancel_handoff, ^token, _settler}
      refute_received {^tag, :cancel_requests, _requests}
      refute_received {:loopex_cancel_result, ^token, _answer}
      send(guard, :stop)
    end
  end

  test "a cancellation before the process begins is handed to the execute caller with the refusal" do
    # Concept: a cancellation that stops a job before its process begins is
    # answered by whoever publishes the refusal, once it is durable -- never by
    # the worker that refused.
    #
    # Technical depth: this case is the execute caller. The worker refuses the
    # job on the first request and hands both that request and one queued
    # behind it to the execute caller, ahead of the cancelled result and from
    # the same sender, so the caller holds them before it can settle; each
    # requester is told the execute caller will answer. The worker answers
    # neither. It used to answer the first `cleaned` before anything was
    # published.
    {worker, _table, tag, _job_id, _caller, guard} = pre_run_worker("pre-run-cancel", nil)
    worker_monitor = Process.monitor(worker)
    assert :erlang.suspend_process(worker)
    first = queue_cancellation(worker)
    second = queue_cancellation(worker)
    assert :erlang.resume_process(worker)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :normal}, 2_000

    {:messages, queued} = Process.info(self(), :messages)
    handed_at = Enum.find_index(queued, &match?({^tag, :cancel_requests, _}, &1))
    result_at = Enum.find_index(queued, &match?({^tag, :worker_result, _, _}, &1))
    assert handed_at < result_at, "the refusal reached its execute caller before its requests"

    me = self()
    assert_received {^tag, :cancel_requests, [{^first, ^me}, {^second, ^me}]}
    assert_received {^tag, :worker_result, {{:cancelled, _, :complete}, 0, :confirmed}, false}
    assert_received {:loopex_cancel_handoff, ^first, ^me}
    assert_received {:loopex_cancel_handoff, ^second, ^me}
    refute_received {:loopex_cancel_result, _token, _answer}
    send(guard, :stop)
  end

  test "a terminated group that was proved gone is reported confirmed" do
    # Concept: terminating a group is not a failure to clean up; proving it gone
    # is confirmed cleanup, and a job that exited on its own stays completed.
    #
    # Technical depth: real cases pair their outcome with whatever cleanup fact
    # the host lets them prove, so a regression that made a terminated group
    # never confirmable would pass them. The two rules that decide it are pinned
    # here on supplied facts: the forced-KILL rule confirms a group with KILL
    # sent, a nonzero Port exit and an empty table, and the exited-command rule
    # reports a confirmed terminated group `completed` with the terminated note
    # and `confirmed`.
    witness = 700
    empty = {:answered, "#{witness} #{witness}\n", 0, witness}

    assert Local.forced_kill_confirmed?(%{
             kill_sent: true,
             port_exit_status: 137,
             table_answer: empty,
             group: 900
           })

    assert {{:completed, output, :complete}, :confirmed} =
             Local.exited_result(0, "done\n", :terminated, true, 4_096)

    assert output =~ "\n[loopex: the command exited, but its process group could not be shown"
    assert output =~ "so the group was terminated. It is confirmed cleaned"

    assert {{:completed, "done\n", :complete}, :confirmed} =
             Local.exited_result(0, "done\n", :quiescent, true, 4_096)

    assert {{:outcome_unknown, unproven, :complete}, :unconfirmed} =
             Local.exited_result(0, "done\n", :unconfirmed, false, 4_096)

    assert unproven =~ "could not be confirmed cleaned"
  end

  test "a command worker exits before run when its execute caller dies" do
    # Concept: a command worker that has only announced readiness cannot survive
    # the caller responsible for sending its run signal.
    #
    # Technical depth: the caller intercepts readiness, publishes the same
    # `{:starting, worker}` entry production publishes, and deliberately withholds
    # `:run`. Its `DOWN` must make the production handshake remove that entry and
    # end the worker. Sending the withheld signal afterwards proves no effect can
    # occur later.
    fixture = fixture("caller-lost-before-run")
    on_exit(fn -> stop_fixture(fixture) end)

    parent = self()
    tag = make_ref()
    job_id = "job-caller-lost-before-run"
    target = Path.join(fixture.workspace, "caller-lost-before-run.txt")
    table = :ets.new(:caller_lost_before_run, [:set, :public])

    caller =
      spawn(fn ->
        receive do
          {^tag, :worker_ready, worker} ->
            true =
              :ets.insert(table, [
                {job_id, {:starting, worker}},
                {{:loopex_process_authority, job_id}, worker, fixture.grace}
              ])

            send(parent, {tag, :worker_ready_intercepted, self(), worker})

            receive do
              {^tag, :release_run} -> send(worker, {tag, :run})
            end
        end
      end)

    {worker, worker_monitor} =
      spawn_monitor(fn ->
        Process.put(:loopex_inflight_table, table)

        case Local.await_owned_process_start(caller, fixture.executor, tag, job_id) do
          {:run, _owner} -> File.write!(target, "escaped")
          :stop -> :ok
        end
      end)

    on_exit(fn ->
      if Process.alive?(caller), do: Process.exit(caller, :kill)
      if Process.alive?(worker), do: Process.exit(worker, :kill)
    end)

    assert_receive {^tag, :worker_ready_intercepted, ^caller, ^worker}, 2_000
    assert :ets.lookup(table, job_id) == [{job_id, {:starting, worker}}]

    assert :ets.lookup(table, {:loopex_process_authority, job_id}) == [
             {{:loopex_process_authority, job_id}, worker, fixture.grace}
           ]

    caller_monitor = Process.monitor(caller)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}, 2_000
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :normal}, 2_000

    assert :ets.lookup(table, job_id) == []
    assert :ets.lookup(table, {:loopex_process_authority, job_id}) == []
    send(worker, {tag, :run})
    refute File.exists?(target), "the command worker acted after its execute caller died"
  end

  test "a command worker refuses a queued run after Local authority is already dead" do
    # Concept: a queued permit is not authority after the Local instance that
    # issued it has died.
    #
    # Technical depth: the caller's `:run` and the guard monitor's `:DOWN`
    # arrive from different senders, so their mailbox order cannot decide which
    # fact happened first. Suspend the worker, queue `:run`, kill the exact
    # guard, and resume only after its death is established. The worker must
    # validate the guard at the point it consumes `:run`; merely selecting the
    # first mailbox entry writes the marker under dead authority.
    fixture = fixture("guard-lost-before-run")
    on_exit(fn -> stop_fixture(fixture) end)
    Process.unlink(fixture.executor)

    parent = self()
    tag = make_ref()
    job_id = "job-guard-lost-before-run"
    target = Path.join(fixture.workspace, "guard-lost-before-run.txt")
    table = :ets.new(:guard_lost_before_run, [:set, :public])

    {worker, worker_monitor} =
      spawn_monitor(fn ->
        Process.put(:loopex_inflight_table, table)

        case Local.await_owned_process_start(parent, fixture.executor, tag, job_id) do
          {:run, _owner} -> File.write!(target, "escaped")
          :stop -> :ok
        end
      end)

    on_exit(fn ->
      resume_if_suspended(worker)
      if Process.alive?(worker), do: Process.exit(worker, :kill)
    end)

    assert_receive {^tag, :worker_ready, ^worker}, 2_000

    true =
      :ets.insert(table, [
        {job_id, {:starting, worker}},
        {{:loopex_process_authority, job_id}, worker, fixture.grace}
      ])

    assert :erlang.suspend_process(worker)

    # Queue the caller's message first, then make it stale before the worker can
    # consume it. This fixes the otherwise scheduler-dependent cross-sender
    # ordering at one deterministic point.
    send(worker, {tag, :run})
    guard_monitor = Process.monitor(fixture.executor)
    Process.exit(fixture.executor, :kill)
    assert_receive {:DOWN, ^guard_monitor, :process, _guard, :killed}, 2_000

    assert :erlang.resume_process(worker)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :normal}, 2_000

    assert :ets.lookup(table, job_id) == []
    assert :ets.lookup(table, {:loopex_process_authority, job_id}) == []

    refute File.exists?(target),
           "the command worker consumed a stale run permit after Local authority died"
  end

  test "a queued port exit cannot outrun Local authority lost before effect completion" do
    # Concept: a command result becomes proved only while the Local hand that
    # admitted it is still authoritative.
    #
    # Technical depth: port exit and owner `:DOWN` are independent signal paths.
    # Hold the real command worker while its real child is still blocked, inject
    # the exact port-exit tuple ahead of the monitor signal, then kill Local
    # before the child can finish. This is deterministic fault injection for the
    # otherwise scheduler-dependent cross-source ordering. Accepting the queued
    # exit without rechecking owner liveness kills the group and reports
    # `completed` even though authority ended first. The correct result remains
    # `outcome_unknown`; cleanup can prove the group ended but cannot recreate
    # the dead receipt owner.
    fixture = fixture("owner-lost-after-port-exit")
    on_exit(fn -> stop_fixture(fixture) end)
    Process.unlink(fixture.executor)

    target = Path.join(fixture.workspace, "command-finished.txt")
    ready = Path.join(fixture.workspace, "command-ready.txt")

    arguments = %{
      "argv" => [
        "/bin/sh",
        "-c",
        "printf ready > \"$1\"; while :; do sleep 1; done; printf finished > \"$2\"",
        "loopex-owner-exit",
        ready,
        target
      ]
    }

    {job, grant} =
      job_and_grant(fixture, "owner-lost-after-port-exit", "loopex.bash", arguments)

    parent = self()

    running =
      Task.async(fn -> Local.execute(fixture.executor, job, grant, notify: parent) end)

    on_exit(fn ->
      case await_command_worker(running.pid, 1) do
        nil -> :ok
        worker -> resume_if_suspended(worker)
      end

      if Process.alive?(running.pid), do: Task.shutdown(running, :brutal_kill)
    end)

    assert_receive {:executor_process_started, job_id, "loopex.bash", ["PATH"]}, 2_000
    assert job_id == job.job_id
    assert await_file(ready), "the real child did not begin its blocked effect"

    worker = await_command_worker(running.pid)
    assert is_pid(worker), "the execute caller did not monitor its command worker"
    port = command_port(worker)
    assert is_port(port), "the command worker did not own its real port"
    assert :erlang.suspend_process(worker)

    # The OS child is deliberately still live here. This exact signal shape is
    # queued first solely to force the adverse mailbox order; the owner dies
    # before production quiesces the group and fixes the result.
    send(worker, {port, {:exit_status, 0}})

    owner_monitor = Process.monitor(fixture.executor)
    Process.exit(fixture.executor, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, _owner, :killed}, 2_000

    assert :erlang.resume_process(worker)

    assert {:ok, %{outcome: :outcome_unknown}} = Task.await(running, 5_000)

    refute File.exists?(target),
           "the child finished an effect after the Local authority that owned it died"
  end

  test "command dispatch uses the caller-monitored pre-run handshake" do
    # Concept: every production command worker watches its execute caller before
    # it announces readiness.
    #
    # Technical depth: the behavioral case above proves the handshake boundary;
    # this compiled-code assertion proves `run_owned_process/10` routes its worker
    # through that boundary and that the boundary installs both monitors before
    # announcing readiness. Bypassing it with the former inline receive or
    # announcing before either monitor makes this assertion fail without a
    # scheduler race.
    module = Local

    assert {:ok, {^module, [{:abstract_code, {:raw_abstract_v1, forms}}]}} =
             :beam_lib.chunks(:code.which(module), [:abstract_code])

    assert run_owned_process =
             Enum.find(forms, &match?({:function, _, :run_owned_process, 10, _}, &1))

    helper_calls =
      matching_terms(run_owned_process, fn
        {:call, _, {:atom, _, :await_owned_process_start}, [_, _, _, _]} -> true
        _other -> false
      end)

    assert length(helper_calls) == 1,
           "run_owned_process/10 must call await_owned_process_start/4 exactly once"

    refute contains_term?(run_owned_process, fn
             {:call, _, callee, [_recipient, message]} ->
               send_call?(callee) and abstract_atom?(message, :worker_ready)

             _other ->
               false
           end),
           "run_owned_process/10 still announces worker readiness outside the handshake"

    assert {:function, _, :await_owned_process_start, 4,
            [
              {:clause, _,
               [
                 {:var, _, caller_name},
                 {:var, _, guard_name},
                 {:var, _, tag_name},
                 {:var, _, _job_id_name}
               ], _, handshake_body}
            ]} = Enum.find(forms, &match?({:function, _, :await_owned_process_start, 4, _}, &1))

    assert [guard_monitor, caller_monitor, ready_announcement | _rest] = handshake_body

    assert match?(
             {:match, _, {:var, _, _},
              {:call, _, {:remote, _, {:atom, _, :erlang}, {:atom, _, :monitor}},
               [{:atom, _, :process}, {:var, _, ^guard_name}]}},
             guard_monitor
           ),
           "the handshake did not monitor Local authority before readiness"

    assert match?(
             {:match, _, {:var, _, _},
              {:call, _, {:remote, _, {:atom, _, :erlang}, {:atom, _, :monitor}},
               [{:atom, _, :process}, {:var, _, ^caller_name}]}},
             caller_monitor
           ),
           "the handshake did not monitor its execute caller before readiness"

    assert match?(
             {:call, _, {:remote, _, {:atom, _, :erlang}, {:atom, _, :send}},
              [
                {:var, _, ^caller_name},
                {:tuple, _,
                 [
                   {:var, _, ^tag_name},
                   {:atom, _, :worker_ready},
                   {:call, _, {:remote, _, {:atom, _, :erlang}, {:atom, _, :self}}, []}
                 ]}
              ]},
             ready_announcement
           ),
           "the handshake announced readiness before both owner monitors existed"
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
    # Two seconds of declared delay: the lookup below polls from the moment the
    # job is dispatched, so the window only has to be longer than one poll, and
    # the case waits out the rest of it before it can read the retained receipt.
    {job, grant} =
      job_and_grant(fixture, "in-flight", "loopex.demo.wait_write", %{
        "relative_path" => "in-flight.txt",
        "content" => "bytes-in-flight",
        "delay_ms" => 2_000
      })

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

  test "a same-digest admission joins before a duplicate caller's grant is revalidated" do
    # Concept: once durable truth says an effect may have begun, a later caller's
    # stale grant cannot turn that operation back into a proved pre-effect
    # refusal.
    #
    # Technical depth: the old permit path validated the duplicate first, tried
    # to write a refusal over the admission, ignored the ledger conflict, and
    # returned the refusal tag anyway. This case installs the exact admission,
    # then presents a deliberately invalid grant through the real permit
    # boundary. The matching marker must decide `:join` before ephemeral grant
    # validation, and the admission record must remain the durable answer.
    fixture = fixture("admission-before-revalidation")
    on_exit(fn -> stop_fixture(fixture) end)
    {job, grant} = job_and_grant(fixture, "admission-before-revalidation", "loopex.demo.write")
    {:ok, prepared} = Ledger.prepare(fixture.ledger, "executor-local", 5_000)

    assert :ok =
             Ledger.with_claim(prepared, fn ->
               Ledger.admit(
                 prepared,
                 Ledger.marker(job),
                 Ledger.open_entry(job, "executor-local")
               )
             end)

    assert {:ok, placement} = GenServer.call(fixture.executor, {:reserve, job}, 10_000)
    reservation_ref = Map.fetch!(placement, :reservation_ref)
    stale_grant = Map.put(grant, :expiry, 0)

    assert {:ok, %{decision: :join}} =
             GenServer.call(
               fixture.executor,
               {:permit, job, stale_grant, reservation_ref},
               10_000
             )

    assert {:ok, %{ledger_kind: "local_effect_admission_v1"}} =
             Ledger.read_marker(prepared, job.job_id)

    GenServer.cast(fixture.executor, {:release, job.job_id, reservation_ref})
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

  test "a pre-reserved unrelated job is rechecked after an effect owner dies" do
    # Concept: queueing a job while this root is healthy is not permission to
    # run it after the root acquires unresolved effect authority.
    #
    # Technical depth: A owns an admitted delayed effect while B obtains only a
    # reservation. The same B holder asks for the later permit after A dies, so
    # this reaches the final authority boundary rather than merely failing a
    # caller-token check. A permit that trusts the earlier reservation admits B;
    # a permit that repeats root reconciliation refuses it before any marker,
    # owner token, dispatch count, or filesystem effect exists.
    fixture = fixture("pre-reserved-after-owner-loss")
    on_exit(fn -> stop_fixture(fixture) end)

    {owned, owned_grant} =
      job_and_grant(fixture, "pre-reserved-owner", "loopex.demo.wait_write")

    {queued, queued_grant} =
      job_and_grant(fixture, "pre-reserved-unrelated", "loopex.demo.write")

    parent = self()

    owner =
      Task.async(fn ->
        Local.execute(fixture.executor, owned, owned_grant, notify: parent)
      end)

    assert_receive {:executor_process_started, owned_job_id, "loopex.demo.wait_write", ["PATH"]},
                   5_000

    assert owned_job_id == owned.job_id

    queued_holder =
      spawn(fn ->
        result = GenServer.call(fixture.executor, {:reserve, queued}, 10_000)
        send(parent, {:unrelated_reserved, self(), result})

        case result do
          {:ok, placement} ->
            reservation_ref = Map.fetch!(placement, :reservation_ref)

            receive do
              :request_permit ->
                permit =
                  GenServer.call(
                    fixture.executor,
                    {:permit, queued, queued_grant, reservation_ref},
                    15_000
                  )

                GenServer.cast(fixture.executor, {:release, queued.job_id, reservation_ref})
                _barrier = GenServer.call(fixture.executor, :stats)
                send(parent, {:unrelated_permit, self(), permit})
            end

          _not_reserved ->
            :ok
        end
      end)

    assert_receive {:unrelated_reserved, ^queued_holder, {:ok, _placement}}, 5_000
    assert await_reservation_count(fixture.executor, queued.job_id, 1, 2_000)

    try do
      _owner_result = Task.shutdown(owner, :brutal_kill)

      assert await_reservation_count(fixture.executor, owned.job_id, 0, 2_000),
             "the admitted owner's reservation did not leave with its process"

      assert await_reservation_count(fixture.executor, queued.job_id, 1, 2_000),
             "the unrelated queued holder lost its reservation before asking for a permit"

      assert Local.receipt(fixture.executor, owned.job_id) == {:error, :effect_unresolved}

      send(queued_holder, :request_permit)

      assert_receive {:unrelated_permit, ^queued_holder, {:error, {:reconciliation_required, 1}}},
                     15_000

      assert %{dispatches: dispatches} = Local.stats(fixture.executor)
      refute Map.has_key?(dispatches, queued.job_id)

      assert {:ok, prepared} = Ledger.prepare(fixture.ledger, "executor-local", 5_000)
      assert Ledger.read_marker(prepared, queued.job_id) == :absent
      refute Ledger.open?(prepared, queued.job_id)
      assert Ledger.open?(prepared, owned.job_id)
      refute File.exists?(Path.join(fixture.workspace, "pre-reserved-unrelated.txt"))
    after
      if Process.alive?(owner.pid), do: Task.shutdown(owner, :brutal_kill)
      if Process.alive?(queued_holder), do: Process.exit(queued_holder, :kill)
    end
  end

  test "a permit repeats root reconciliation after blocking final validation" do
    # Concept: a healthy root observed before validation is not permission to
    # ignore effect authority that becomes unresolved while validation waits.
    #
    # Technical depth: A owns an admitted delayed effect. B enters its permit
    # decision while A is live, then blocks in the real workspace-lease resolve
    # after that first root snapshot. Killing A's exact reservation holder there
    # queues its `DOWN` behind B's serialized call, so only a post-validation
    # snapshot that samples live operation holders can see A's open entry as
    # unresolved. Without that second snapshot B receives an admitted permit.
    fixture = fixture("post-validation-reconciliation")
    on_exit(fn -> stop_fixture(fixture) end)

    {owned, owned_grant} =
      job_and_grant(fixture, "post-validation-owner", "loopex.demo.wait_write")

    {queued, queued_grant} =
      job_and_grant(fixture, "post-validation-unrelated", "loopex.demo.write")

    parent = self()

    owner =
      Task.async(fn ->
        Local.execute(fixture.executor, owned, owned_grant, notify: parent)
      end)

    assert_receive {:executor_process_started, owned_job_id, "loopex.demo.wait_write", ["PATH"]},
                   5_000

    assert owned_job_id == owned.job_id

    queued_holder =
      spawn(fn ->
        {:ok, placement} = GenServer.call(fixture.executor, {:reserve, queued}, 10_000)
        reservation_ref = Map.fetch!(placement, :reservation_ref)
        send(parent, {:post_validation_reserved, self()})

        receive do
          :request_permit ->
            answer =
              GenServer.call(
                fixture.executor,
                {:permit, queued, queued_grant, reservation_ref},
                15_000
              )

            GenServer.cast(fixture.executor, {:release, queued.job_id, reservation_ref})
            send(parent, {:post_validation_permit, self(), answer})
        end
      end)

    assert_receive {:post_validation_reserved, ^queued_holder}, 5_000
    :erlang.suspend_process(fixture.lease)

    try do
      send(queued_holder, :request_permit)

      assert await_queued_call(fixture.lease),
             "the permit never reached its blocking final lease validation"

      _owner_result = Task.shutdown(owner, :brutal_kill)
      refute Process.alive?(owner.pid), "the admitted effect owner remained live"

      :erlang.resume_process(fixture.lease)

      assert_receive {:post_validation_permit, ^queued_holder,
                      {:error, {:reconciliation_required, 1}}},
                     15_000

      _permit_barrier = Local.stats(fixture.executor)
      assert %{dispatches: dispatches} = Local.stats(fixture.executor)
      refute Map.has_key?(dispatches, queued.job_id)

      assert {:ok, prepared} = Ledger.prepare(fixture.ledger, "executor-local", 5_000)
      assert Ledger.read_marker(prepared, queued.job_id) == :absent
      refute Ledger.open?(prepared, queued.job_id)
      assert Ledger.open?(prepared, owned.job_id)
      refute File.exists?(Path.join(fixture.workspace, "post-validation-unrelated.txt"))
    after
      if Process.alive?(fixture.lease) and
           Process.info(fixture.lease, :status) == {:status, :suspended},
         do: :erlang.resume_process(fixture.lease)

      if Process.alive?(owner.pid), do: Task.shutdown(owner, :brutal_kill)
      if Process.alive?(queued_holder), do: Process.exit(queued_holder, :kill)
    end
  end

  # Concept: malformed durable authority is unavailability, never evidence that
  # this root is clear to run another effect.
  #
  # Technical depth: `reconcile/2` returns the open-snapshot error directly. A
  # fail-open branch that turns that error into `nil` admits this job and writes
  # its file, so the case drives the real reserve/permit boundary and checks both
  # the exact refusal and absence of every new-effect artifact.
  test "a malformed open authority snapshot cannot become permission" do
    fixture = fixture("malformed-open-snapshot")
    on_exit(fn -> stop_fixture(fixture) end)
    {job, grant} = job_and_grant(fixture, "malformed-open-snapshot", "loopex.demo.write")

    assert {:ok, placement} = GenServer.call(fixture.executor, {:reserve, job}, 10_000)
    reservation_ref = Map.fetch!(placement, :reservation_ref)

    File.write!(Path.join([fixture.ledger, "open", "malformed"]), "not a ledger record")

    assert GenServer.call(
             fixture.executor,
             {:permit, job, grant, reservation_ref},
             10_000
           ) == {:error, {:ledger_unavailable, :malformed_record}}

    GenServer.cast(fixture.executor, {:release, job.job_id, reservation_ref})
    _release_barrier = Local.stats(fixture.executor)

    assert {:ok, prepared} = Ledger.prepare(fixture.ledger, "executor-local", 5_000)
    assert Ledger.read_marker(prepared, job.job_id) == :absent
    refute Ledger.open?(prepared, job.job_id)
    refute File.exists?(Path.join(fixture.workspace, "malformed-open-snapshot.txt"))
  end

  # Concept: every unresolved open operation contributes to the quarantine; a
  # root does not become usable merely because more than one needs repair.
  #
  # Technical depth: two valid foreign admissions are installed under one real
  # root claim. A shortcut that treats a list with two or more members as clear
  # admits the unrelated effect, while the correct snapshot reports the exact
  # unresolved count and publishes nothing for the new job.
  test "several unresolved open authorities preserve their exact quarantine count" do
    fixture = fixture("several-unresolved-open")
    on_exit(fn -> stop_fixture(fixture) end)

    {first, _first_grant} = job_and_grant(fixture, "unresolved-first", "loopex.demo.write")
    {second, _second_grant} = job_and_grant(fixture, "unresolved-second", "loopex.demo.write")
    {job, grant} = job_and_grant(fixture, "after-several-unresolved", "loopex.demo.write")
    assert {:ok, prepared} = Ledger.prepare(fixture.ledger, "executor-local", 5_000)

    assert :ok =
             Ledger.with_claim(prepared, fn ->
               with :ok <-
                      Ledger.admit(
                        prepared,
                        Ledger.marker(first),
                        Ledger.open_entry(first, "foreign-executor")
                      ) do
                 Ledger.admit(
                   prepared,
                   Ledger.marker(second),
                   Ledger.open_entry(second, "foreign-executor")
                 )
               end
             end)

    assert Local.execute(fixture.executor, job, grant) ==
             {:error, {:reconciliation_required, 2}}

    assert Ledger.read_marker(prepared, job.job_id) == :absent
    refute Ledger.open?(prepared, job.job_id)
    refute File.exists?(Path.join(fixture.workspace, "after-several-unresolved.txt"))
  end

  # Concept: the quarantine count describes only unresolved authority. Work
  # still owned by this exact Local instance remains protected, but it is not an
  # operator reconciliation item.
  #
  # Technical depth: one delayed job supplies a live operation-owner token while
  # one foreign open entry is installed beside it. Counting the complete
  # snapshot instead of the filtered unresolved set reports two and misdirects
  # recovery; the correct refusal reports one and starts no third effect.
  test "live owned work does not inflate the unresolved quarantine count" do
    fixture = fixture("exact-unresolved-count")
    on_exit(fn -> stop_fixture(fixture) end)

    {owned, owned_grant} =
      job_and_grant(fixture, "exact-count-owned", "loopex.demo.wait_write", %{
        "relative_path" => "exact-count-owned.txt",
        "content" => "bytes-exact-count-owned",
        "delay_ms" => 30_000
      })

    {foreign, _foreign_grant} =
      job_and_grant(fixture, "exact-count-foreign", "loopex.demo.write")

    {job, grant} = job_and_grant(fixture, "exact-count-new", "loopex.demo.write")
    parent = self()

    owner =
      Task.async(fn ->
        Local.execute(fixture.executor, owned, owned_grant, notify: parent)
      end)

    assert_receive {:executor_process_started, owned_job_id, "loopex.demo.wait_write", ["PATH"]},
                   5_000

    assert owned_job_id == owned.job_id

    try do
      assert {:ok, prepared} = Ledger.prepare(fixture.ledger, "executor-local", 5_000)

      assert :ok =
               Ledger.with_claim(prepared, fn ->
                 Ledger.admit(
                   prepared,
                   Ledger.marker(foreign),
                   Ledger.open_entry(foreign, "foreign-executor")
                 )
               end)

      assert Local.execute(fixture.executor, job, grant) ==
               {:error, {:reconciliation_required, 1}}

      assert Ledger.read_marker(prepared, job.job_id) == :absent
      refute Ledger.open?(prepared, job.job_id)
      assert Ledger.open?(prepared, owned.job_id)
      assert Ledger.open?(prepared, foreign.job_id)
      refute File.exists?(Path.join(fixture.workspace, "exact-count-new.txt"))
    after
      if Process.alive?(owner.pid), do: Task.shutdown(owner, :brutal_kill)
    end
  end

  test "a permit whose holder dies during final validation starts no effect" do
    # Concept: the process that owns a queued reservation must still be alive
    # when the final permit is fixed; a dead caller cannot leave runnable work.
    #
    # Technical depth: suspending the lease holds the permit handler inside its
    # last bounded validation after it acquired the root claim. The holder dies
    # there, before the server can process its queued `DOWN`. Live-holder checks
    # after validation and at owner-token insertion must therefore observe the
    # process itself, withhold the permit, and leave no durable admission.
    fixture = fixture("permit-holder-dies")
    on_exit(fn -> stop_fixture(fixture) end)
    {job, grant} = job_and_grant(fixture, "permit-holder-dies", "loopex.demo.write")
    parent = self()

    holder =
      spawn(fn ->
        {:ok, placement} = GenServer.call(fixture.executor, {:reserve, job}, 10_000)
        reservation_ref = Map.fetch!(placement, :reservation_ref)
        send(parent, {:permit_holder_reserved, self(), reservation_ref})

        receive do
          :request_permit ->
            GenServer.call(
              fixture.executor,
              {:permit, job, grant, reservation_ref},
              15_000
            )
        end
      end)

    assert_receive {:permit_holder_reserved, ^holder, _reservation_ref}, 5_000
    :erlang.suspend_process(fixture.lease)

    try do
      send(holder, :request_permit)

      assert await_queued_call(fixture.lease),
             "the permit never reached the final workspace-lease validation"

      Process.exit(holder, :kill)
      :erlang.resume_process(fixture.lease)

      _permit_barrier = Local.stats(fixture.executor)

      assert await_reservation_count(fixture.executor, job.job_id, 0, 2_000)
      assert Local.receipt(fixture.executor, job.job_id) == :absent
      assert %{dispatches: dispatches} = Local.stats(fixture.executor)
      refute Map.has_key?(dispatches, job.job_id)

      assert {:ok, prepared} = Ledger.prepare(fixture.ledger, "executor-local", 5_000)
      assert Ledger.read_marker(prepared, job.job_id) == :absent
      refute Ledger.open?(prepared, job.job_id)
      refute File.exists?(Path.join(fixture.workspace, "permit-holder-dies.txt"))
    after
      if Process.alive?(fixture.lease) and
           Process.info(fixture.lease, :status) == {:status, :suspended},
         do: :erlang.resume_process(fixture.lease)

      if Process.alive?(holder), do: Process.exit(holder, :kill)
    end
  end

  test "a queued permit cannot ignore an operation whose settlement became quarantined" do
    # Concept: once an operation stops being live and its open authority remains,
    # an already-queued unrelated permit must see the quarantine before it can
    # start another effect.
    #
    # Technical depth: settlement runs in the caller while permits serialize in
    # the executor. The close seam holds A's root claim as B's permit queues, then
    # fails without removing A's open entry. If A's owner token survives until a
    # later release cast, B runs first and excludes that open entry as though A
    # were still live. Removing the exact owner token when settlement begins
    # makes the open entry visible to B's first post-claim reconciliation.
    parent = self()

    close = fn _ledger, job_id ->
      send(parent, {:quarantine_close_started, job_id, self()})

      receive do
        {:finish_quarantine_close, ^job_id} -> {:error, :forced_close_failure}
      end
    end

    fixture = fixture("queued-permit-after-quarantine", open_authority_close: close)
    on_exit(fn -> stop_fixture(fixture) end)

    {owned, owned_grant} =
      job_and_grant(fixture, "quarantined-owner", "loopex.demo.write")

    {queued, queued_grant} =
      job_and_grant(fixture, "queued-after-quarantine", "loopex.demo.write")

    queued_holder =
      spawn(fn ->
        {:ok, placement} = GenServer.call(fixture.executor, {:reserve, queued}, 10_000)
        reservation_ref = Map.fetch!(placement, :reservation_ref)
        send(parent, {:quarantine_waiter_reserved, self()})

        receive do
          :request_quarantined_permit ->
            send(parent, {:quarantine_waiter_calling, self()})

            answer =
              GenServer.call(
                fixture.executor,
                {:permit, queued, queued_grant, reservation_ref},
                15_000
              )

            send(parent, {:quarantine_waiter_answer, self(), answer})
        end
      end)

    assert_receive {:quarantine_waiter_reserved, ^queued_holder}, 5_000

    owner =
      spawn(fn ->
        result = Local.execute(fixture.executor, owned, owned_grant)
        send(parent, {:quarantined_owner_result, self(), result})

        receive do
          :release_quarantined_owner -> :ok
        end
      end)

    on_exit(fn ->
      if Process.alive?(owner), do: Process.exit(owner, :kill)
    end)

    assert_receive {:quarantine_close_started, owned_job_id, close_worker}, 5_000
    assert owned_job_id == owned.job_id

    send(queued_holder, :request_quarantined_permit)
    assert_receive {:quarantine_waiter_calling, ^queued_holder}, 2_000

    # Give the holder a scheduler turn to enter its synchronous call. The
    # executor either has that call queued or has already taken it and is waiting
    # for the root claim held by A; both establish the ordering this case needs.
    Process.sleep(25)
    refute_received {:quarantine_waiter_answer, ^queued_holder, _answer}

    send(close_worker, {:finish_quarantine_close, owned.job_id})

    assert_receive {:quarantined_owner_result, ^owner,
                    {:error,
                     {:effect_settling, {:open_authority_not_removed, :forced_close_failure}}}},
                   15_000

    assert_receive {:quarantine_waiter_answer, ^queued_holder, queued_answer}, 15_000

    assert queued_answer == {:error, {:reconciliation_required, 1}},
           "the queued permit ignored the quarantined operation: #{inspect(queued_answer)}"

    refute File.exists?(Path.join(fixture.workspace, "queued-after-quarantine.txt"))
    send(owner, :release_quarantined_owner)
  end

  test "owner-aware bounded work stops a filesystem effect when Local authority is lost" do
    # Concept: losing the Local hand ends a filesystem effect worker; a blocked
    # caller is not the authority that keeps it alive.
    #
    # Technical depth: this asks the exposed owner-aware boundary directly with
    # a closure whose file effect is held behind a test-owned message. Killing the
    # exact Local owner must kill and confirm that closure before answering. The
    # separate wiring case below proves production filesystem dispatch selects
    # this boundary, without adding a caller-controlled switch to shipped code.
    fixture = fixture("filesystem-owner-loss")
    on_exit(fn -> stop_fixture(fixture) end)
    Process.unlink(fixture.executor)

    parent = self()
    target = Path.join(fixture.workspace, "filesystem-owner-loss.txt")
    barrier_ref = make_ref()

    running =
      Task.async(fn ->
        lease_monitor = Process.monitor(fixture.lease)

        try do
          Local.bounded_work(
            fn ->
              send(parent, {barrier_ref, :filesystem_worker_ready, self()})

              receive do
                {^barrier_ref, :perform_effect} -> File.write!(target, "escaped")
              end
            end,
            30_000,
            {lease_monitor, fixture.lease},
            fixture.executor
          )
        after
          Process.demonitor(lease_monitor, [:flush])
        end
      end)

    assert_receive {^barrier_ref, :filesystem_worker_ready, effect_worker}, 2_000
    effect_monitor = Process.monitor(effect_worker)
    executor_monitor = Process.monitor(fixture.executor)
    Process.exit(fixture.executor, :kill)
    assert_receive {:DOWN, ^executor_monitor, :process, _executor, :killed}, 2_000

    assert {:abandoned, :effect_owner_lost, true, :none} = Task.await(running, 2_000)
    assert_receive {:DOWN, ^effect_monitor, :process, ^effect_worker, :killed}, 2_000

    send(effect_worker, {barrier_ref, :perform_effect})
    refute File.exists?(target), "the filesystem worker acted after its Local owner died"
  end

  test "filesystem dispatch selects the owner-aware bounded work boundary" do
    # Concept: every production filesystem effect is guarded by the Local
    # authority that admitted it.
    #
    # Technical depth: the behavioral case above proves the owner-aware guardian;
    # this compiled-code assertion proves `run_bounded_tool/6` supplies
    # `effect_owner/0` as its fourth argument. Inspecting BEAM abstract code keeps
    # the proof deterministic while avoiding a test-only branch in production.
    module = Local

    assert {:ok, {^module, [{:abstract_code, {:raw_abstract_v1, forms}}]}} =
             :beam_lib.chunks(:code.which(module), [:abstract_code])

    assert run_bounded_tool =
             Enum.find(forms, &match?({:function, _, :run_bounded_tool, 6, _}, &1))

    guarded_calls =
      matching_terms(run_bounded_tool, fn
        {:call, _, {:atom, _, :bounded_guardian_with_remaining}, _arguments} -> true
        _other -> false
      end)

    assert [guarded_call] = guarded_calls

    assert match?(
             {:call, _, {:atom, _, :bounded_guardian_with_remaining},
              [_, _, _, {:call, _, {:atom, _, :effect_owner}, []}]},
             guarded_call
           ),
           "run_bounded_tool/6 did not call the guardian with effect_owner/0"
  end

  test "a reserve blocked by a held claim is answered inside its own bound" do
    # The bound is this executor's, not this case's: it is a start option whose
    # default is the shipped five seconds, so the ceiling can be named here and
    # the whole of it spent and answered in a fraction of a second. Nothing about
    # the claim is simulated -- a real peer holds a real claim on the same root
    # until this case has its answer -- and the default the host gets when it
    # names nothing is asserted once, below, against the executor that enforces
    # it. The peer is released by a message rather than after a sleep, so no
    # slack has to be guessed on the lower side, and the upper assertion is made
    # against the shipped default rather than against the named ceiling: waiting
    # five seconds here is what a server that ignored the option would do, and
    # that is the only wait this case has to exclude.
    default_fixture = fixture("reservation-claim-default")
    on_exit(fn -> stop_fixture(default_fixture) end)

    assert :sys.get_state(default_fixture.executor).claim_wait_ms == 5_000,
           "the shipped admission claim ceiling is no longer five seconds"

    claim_wait_ms = 300
    fixture = fixture("reservation-claim", claim_wait_ms: claim_wait_ms)
    on_exit(fn -> stop_fixture(fixture) end)
    {job, grant} = job_and_grant(fixture, "claim", "loopex.demo.write")
    {:ok, prepared} = Ledger.prepare(fixture.ledger, "executor-local", 5_000)
    parent = self()

    holder =
      Task.async(fn ->
        Ledger.with_claim(prepared, fn ->
          send(parent, :reservation_claim_held)

          receive do
            :release_reservation_claim -> :ok
          end
        end)
      end)

    assert_receive :reservation_claim_held, 1_000
    started = System.monotonic_time(:millisecond)
    result = Local.execute(fixture.executor, job, grant)
    elapsed = System.monotonic_time(:millisecond) - started
    send(holder.pid, :release_reservation_claim)

    assert {:error, {:ledger_unavailable, :root_claim_held}} = result

    assert elapsed >= div(claim_wait_ms * 9, 10),
           "the server answered after #{elapsed} ms without spending its claim wait"

    assert elapsed < 4_500,
           "the caller waited #{elapsed} ms, which is the shipped five-second " <>
             "default rather than the ceiling this executor was given"

    Task.await(holder, 10_000)
    assert :absent = Local.receipt(fixture.executor, job.job_id)
  end

  defp fixture(label, extra \\ []) do
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
        [
          identity: "executor-local",
          epoch: 7,
          fencing_token: fence,
          workspace_leases: %{lease_id => lease},
          ledger_root: ledger
        ] ++ extra
      )

    %{
      root: root,
      workspace: workspace,
      ledger: ledger,
      lease_id: lease_id,
      fence: fence,
      lease: lease,
      executor: executor,
      grace: Keyword.get(extra, :cleanup_grace_ms, Executor.default_cleanup_grace_ms())
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

  defp await_queued_call(pid, attempts \\ 200)
  defp await_queued_call(_pid, 0), do: false

  defp await_queued_call(pid, attempts) do
    queued? =
      case Process.info(pid, :messages) do
        {:messages, messages} -> Enum.any?(messages, &match?({:"$gen_call", _from, _}, &1))
        _dead -> false
      end

    if queued? do
      true
    else
      Process.sleep(5)
      await_queued_call(pid, attempts - 1)
    end
  end

  defp job_and_grant(fixture, label, tool_id),
    do: job_and_grant(fixture, label, tool_id, tool_arguments(label, tool_id))

  defp job_and_grant(fixture, label, tool_id, arguments) do
    {:ok, tool} = Local.tool(tool_id)
    now = System.system_time(:millisecond)

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

  defp await_command_worker(caller, attempts \\ 200)
  defp await_command_worker(_caller, 0), do: nil

  defp await_command_worker(caller, attempts) do
    worker =
      case Process.info(caller, :monitors) do
        {:monitors, monitors} ->
          Enum.find_value(monitors, fn
            {:process, pid} -> if is_port(command_port(pid)), do: pid
            _other -> nil
          end)

        _dead ->
          nil
      end

    if worker do
      worker
    else
      Process.sleep(5)
      await_command_worker(caller, attempts - 1)
    end
  end

  defp command_port(pid) when is_pid(pid) do
    case Process.info(pid, :links) do
      {:links, links} -> Enum.find(links, &is_port/1)
      _dead -> nil
    end
  end

  defp await_file(path, attempts \\ 400)
  defp await_file(_path, 0), do: false

  defp await_file(path, attempts) do
    if File.exists?(path) do
      true
    else
      Process.sleep(5)
      await_file(path, attempts - 1)
    end
  end

  defp resume_if_suspended(pid) do
    if Process.alive?(pid) and Process.info(pid, :status) == {:status, :suspended} do
      :erlang.resume_process(pid)
    else
      :ok
    end
  end

  defp maybe_delay(arguments, "loopex.demo.wait_write"), do: Map.put(arguments, "delay_ms", 5_000)
  defp maybe_delay(arguments, _tool), do: arguments

  defp tool_arguments(label, "loopex.write"),
    do: %{"path" => "#{label}.txt", "content" => "bytes-#{label}"}

  defp tool_arguments(label, tool_id) do
    %{"relative_path" => "#{label}.txt", "content" => "bytes-#{label}"}
    |> maybe_delay(tool_id)
  end

  defp wrong(:attempt, grant), do: grant.attempt + 1
  defp wrong(:expiry, _grant), do: System.system_time(:millisecond) - 1
  defp wrong(:fencing_token, grant), do: grant.fencing_token + 1

  defp wrong(field, grant) do
    case Map.get(grant, field) do
      value when is_binary(value) -> value <> "-wrong"
      _other -> "wrong"
    end
  end

  defp contains_term?(term, predicate) do
    predicate.(term) or
      case term do
        tuple when is_tuple(tuple) ->
          tuple |> Tuple.to_list() |> Enum.any?(&contains_term?(&1, predicate))

        list when is_list(list) ->
          Enum.any?(list, &contains_term?(&1, predicate))

        _leaf ->
          false
      end
  end

  defp matching_terms(term, predicate) do
    own = if predicate.(term), do: [term], else: []

    children =
      case term do
        tuple when is_tuple(tuple) -> Tuple.to_list(tuple)
        list when is_list(list) -> list
        _leaf -> []
      end

    own ++ Enum.flat_map(children, &matching_terms(&1, predicate))
  end

  defp send_call?({:atom, _, :send}), do: true

  defp send_call?({:remote, _, {:atom, _, :erlang}, {:atom, _, :send}}),
    do: true

  defp send_call?(_callee), do: false

  defp abstract_atom?(term, value) do
    contains_term?(term, fn
      {:atom, _, ^value} -> true
      _other -> false
    end)
  end

  # A command worker waiting in the start handshake for `job_id`. Its caller is
  # this case unless the case will kill the caller. Its guard is a stand-in
  # authority that owns the in-flight table, as the executor does, so the
  # guard's death takes the table and with it any hand-off claim.
  defp pre_run_worker(job_id, exit) do
    tag = make_ref()
    parent = self()

    guard =
      spawn(fn ->
        table = :ets.new(:pre_run_worker, [:set, :public])
        send(parent, {:pre_run_table, self(), table})
        receive(do: (:stop -> :ok))
      end)

    assert_receive {:pre_run_table, ^guard, table}, 2_000

    caller =
      if exit == :caller_down,
        do: spawn(fn -> receive(do: (:stop -> :ok)) end),
        else: parent

    worker =
      spawn(fn ->
        Process.put(:loopex_inflight_table, table)
        send(parent, {:pre_run_worker, self()})
        Local.await_owned_process_start(caller, guard, tag, job_id)
      end)

    assert_receive {:pre_run_worker, ^worker}, 2_000

    assert {:ok, :ready} =
             await_mailbox(worker, fn _messages ->
               Process.info(worker, [:current_function, :status]) ==
                 [current_function: {Local, :await_owned_process_start, 4}, status: :waiting]
             end)

    if caller == parent, do: assert_receive({^tag, :worker_ready, ^worker}, 2_000)
    {worker, table, tag, job_id, caller, guard}
  end

  defp queue_cancellation(worker) do
    token = make_ref()
    episode = {System.monotonic_time(:millisecond) + 1_000, 1_000, "/bin/ps"}
    send(worker, {:loopex_cancel_pending, token, self(), episode})
    token
  end

  # Returns `{:ok, :ready}` once `predicate` holds for `pid`'s queued messages.
  defp await_mailbox(pid, predicate, attempts \\ 400) do
    {:messages, messages} = Process.info(pid, :messages)

    cond do
      predicate.(messages) -> {:ok, :ready}
      attempts == 0 -> :error
      true -> Process.sleep(5) && await_mailbox(pid, predicate, attempts - 1)
    end
  end

  defp down_from?(messages, pid),
    do: Enum.any?(messages, &match?({:DOWN, _, :process, ^pid, _}, &1))

  # Runs `work` in this process with call tracing on the named private
  # functions of `Local`, and returns `{name, arguments}` for every traced call
  # in order. Trace delivery is awaited before the collector reports, and the
  # patterns and flags are removed even when `work` fails.
  defp trace_local_calls(functions, work) do
    collector = spawn_link(fn -> collect_traced_calls([]) end)
    Code.ensure_loaded!(Local)

    for {name, arity} <- functions do
      assert :erlang.trace_pattern({Local, name, arity}, true, [:local]) == 1,
             "#{name}/#{arity} is not a function of Local to trace"
    end

    :erlang.trace(self(), true, [:call, {:tracer, collector}])

    try do
      work.()
    after
      :erlang.trace(self(), false, [:call])

      for {name, arity} <- functions,
          do: :erlang.trace_pattern({Local, name, arity}, false, [:local])
    end

    delivered = :erlang.trace_delivered(self())
    assert_receive {:trace_delivered, _pid, ^delivered}, 5_000
    send(collector, {:report, self()})
    assert_receive {:traced_calls, events}, 5_000
    events
  end

  defp collect_traced_calls(events) do
    receive do
      {:trace, _pid, :call, {Local, name, arguments}} ->
        collect_traced_calls([{name, arguments} | events])

      {:report, requester} ->
        send(requester, {:traced_calls, Enum.reverse(events)})
    end
  end

  # A stand-in launch owner published for `job_id` with the committed period
  # `grace`, which hands the one cancellation request it receives to `act`.
  defp stand_in_owner(job_id, grace, act) do
    table = :ets.new(:stand_in_owner, [:set, :public])
    parent = self()

    worker =
      spawn(fn ->
        Process.put(:loopex_inflight_table, table)
        send(parent, {:stand_in_owner, self()})

        receive do
          {:loopex_cancel_pending, token, reply_to, {_until, ^grace, _probe} = episode} ->
            act.(token, reply_to, episode)
        end
      end)

    assert_receive {:stand_in_owner, ^worker}, 1_000

    true =
      :ets.insert(table, [
        {job_id, 4_294_967_000},
        {{:loopex_process_authority, job_id}, worker, grace}
      ])

    {worker, job_id, table}
  end

  # Returns only once the monotonic clock the executor's cleanup episodes use
  # has moved past `instant`.
  defp wait_past(instant) do
    remaining = instant - System.monotonic_time(:millisecond)

    if remaining >= 0 do
      Process.sleep(remaining + 1)
      wait_past(instant)
    end
  end

  defp stop_fixture(fixture) do
    if Process.alive?(fixture.executor), do: GenServer.stop(fixture.executor)
    if Process.alive?(fixture.lease), do: GenServer.stop(fixture.lease)
    File.rm_rf!(fixture.root)
  end
end
