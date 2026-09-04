defmodule Loopex.Executor.Local.PostClosureHotfixTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Loopex.Executor.Local
  alias Loopex.Executor.Local.Ledger
  alias Loopex.Executor.Local.WorkspaceLease
  @fence 23
  @max_uint64 18_446_744_073_709_551_615

  defmodule SlowStore do
    @moduledoc false
    @behaviour Loopex.ArtifactStore

    alias LoopexProtocol.Canonical

    def start(delay_ms),
      do: Agent.start_link(fn -> %{delay: delay_ms, objects: %{}, uses: %{}} end)

    def put(pid, bytes, %{media_type: media_type, role: role, metadata: metadata}) do
      Process.sleep(Agent.get(pid, & &1.delay))

      digest = Canonical.digest_bytes(bytes)
      locator = "slow:" <> digest
      object = %{digest: digest, size: byte_size(bytes), locator: locator}

      artifact_use = %{
        canonicalization_version: Canonical.version(),
        object_digest: object.digest,
        object_size: object.size,
        object_locator: object.locator,
        media_type: media_type,
        role: role,
        metadata: metadata
      }

      use_digest = Canonical.digest(["artifact-use-v2", artifact_use])

      :ok =
        Agent.update(pid, fn state ->
          %{
            state
            | objects: Map.put(state.objects, locator, {object, bytes}),
              uses: Map.put(state.uses, "use:" <> use_digest, artifact_use)
          }
        end)

      {:ok,
       Map.merge(object, %{
         media_type: media_type,
         role: role,
         use_canonicalization_version: Canonical.version(),
         use_digest: use_digest,
         use_locator: "use:" <> use_digest
       })}
    end

    def put(_pid, _bytes, _unnormalized), do: {:error, :adapter_received_unnormalized_use}

    def fetch(pid, object) do
      case Agent.get(pid, &Map.fetch(&1.objects, object.locator)) do
        {:ok, {_object, bytes}} -> {:ok, bytes}
        :error -> {:error, :unknown_artifact}
      end
    end

    def stat(pid, locator) do
      case Agent.get(pid, &Map.fetch(&1.objects, locator)) do
        {:ok, {object, _bytes}} -> {:ok, object}
        :error -> {:error, :unknown_artifact}
      end
    end

    def describe(pid, use_locator) do
      case Agent.get(pid, &Map.fetch(&1.uses, use_locator)) do
        {:ok, use} -> {:ok, use}
        :error -> {:error, :unknown_artifact_use}
      end
    end
  end

  # F3
  test "a job still open on the shared root is unconfirmed at an instance that does not own it" do
    # Concept: cancellation is a claim about an effect, and one executor's empty
    # in-flight table says nothing about an effect another executor admitted on
    # the same durable root.
    #
    # Technical depth: ADR 0016 admits `cleaned` only from a matching durable
    # refusal or independently confirmed cleanup; absence, conflict, or an
    # unreadable root is `unconfirmed`. Deciding from process-local state alone
    # reports a live cross-instance effect as cleaned after a restart.
    root = workspace()
    ledger = ledger_root()
    {owner, owner_lease} = executor_on(root, ledger, cleanup_grace_ms: 2_000)
    {peer, _peer_lease} = executor_on(root, ledger, cleanup_grace_ms: 2_000)

    ready = Path.join(root, "cross-instance-ready")
    job_id = "cross-instance-#{System.unique_integer([:positive])}"

    running =
      Task.async(fn ->
        run(root, "loopex.bash", %{"command" => "printf ready > #{ready}; sleep 20"}, %{
          executor: owner,
          lease_id: owner_lease,
          job_id: job_id,
          cleanup_grace_ms: 2_000
        })
      end)

    try do
      assert wait_for_file(ready), "the owning instance never started its command"

      assert Local.cancel(peer, job_id) == {:ok, :unconfirmed},
             "an instance with no local record of a job open on its own root reported it cleaned"

      # A job no instance has admitted on a readable root really is settled.
      assert Local.cancel(peer, "absent-#{System.unique_integer([:positive])}") ==
               {:ok, :cleaned}
    after
      _answer = Local.cancel(owner, job_id)

      case Task.yield(running, 30_000) do
        nil -> Task.shutdown(running, :brutal_kill)
        _settled -> :ok
      end
    end
  end

  # F4
  test "the committed job period rather than the executor default bounds this job's cleanup" do
    # Concept: the period a job's cleanup spends is the period its request
    # committed, which is the period its receipt reports.
    #
    # Technical depth: ADR 0016 makes the committed `JobRequest` value canonical
    # and reduces the executor start option to a default for jobs that name
    # none. Spending the start option instead makes the receipt name a period the
    # cleanup did not run under.
    root = workspace()
    {executor, lease_id} = executor_with(root, cleanup_grace_ms: 20_000)

    {ms, result} =
      elapsed(fn ->
        run(root, "loopex.bash", %{"command" => stubborn_group_command()}, %{
          executor: executor,
          lease_id: lease_id,
          cleanup_grace_ms: 400
        })
      end)

    assert {:ok, receipt} = result
    assert receipt.cleanup_grace_ms == 400

    assert ms < 3_000,
           "a job committing a 400ms period spent #{ms}ms, which is the executor's 20000ms " <>
             "start default rather than the period the job committed"
  end

  # F4
  test "a cancellation spends the cancelled job's committed period" do
    root = workspace()
    {executor, lease_id} = executor_with(root, cleanup_grace_ms: 20_000)
    ready = Path.join(root, "committed-cancel-ready")
    job_id = "committed-cancel-#{System.unique_integer([:positive])}"

    running =
      Task.async(fn ->
        run(
          root,
          "loopex.bash",
          %{"command" => "trap '' TERM; printf ready > #{ready}; sleep 20"},
          %{
            executor: executor,
            lease_id: lease_id,
            job_id: job_id,
            cleanup_grace_ms: 400
          }
        )
      end)

    try do
      assert wait_for_file(ready), "the command never started, so there was nothing to cancel"
      {ms, answer} = elapsed(fn -> Local.cancel(executor, job_id) end)

      assert answer in [{:ok, :cleaned}, {:ok, :unconfirmed}]

      assert ms < 3_000,
             "cancelling a job committing a 400ms period spent #{ms}ms, which is the " <>
               "executor's 20000ms start default"
    after
      case Task.yield(running, 30_000) do
        nil -> Task.shutdown(running, :brutal_kill)
        _settled -> :ok
      end
    end
  end

  # F5
  test "a settlement that cannot remove its open record never reports confirmed cleanup" do
    # Concept: a receipt that says its cleanup is confirmed while this job's open
    # authority is still on the root describes a state that does not exist.
    #
    # Technical depth: ADR 0016 removes an open entry only under exact authority
    # proof and quarantines the root while one is unresolved. Discarding the
    # removal's result hands a caller success while every later effect on that
    # root is refused for reconciliation.
    root = workspace()
    ledger = ledger_root()
    {executor, lease_id} = executor_on(root, ledger, cleanup_grace_ms: 2_000)
    ready = Path.join(root, "settlement-ready")
    job_id = "settlement-#{System.unique_integer([:positive])}"

    running =
      Task.async(fn ->
        run(root, "loopex.bash", %{"command" => "printf ready > #{ready}; sleep 1"}, %{
          executor: executor,
          lease_id: lease_id,
          job_id: job_id,
          cleanup_grace_ms: 2_000
        })
      end)

    assert wait_for_file(ready), "the command never started"

    claim = Path.join(ledger, "claim")
    on_exit(fn -> File.rmdir(claim) end)
    assert :ok = File.mkdir(claim)

    assert {:ok, receipt} = Task.await(running, 30_000)

    assert File.regular?(Path.join([ledger, "open", digest(job_id)])),
           "the open entry was removed while the root claim was held"

    assert receipt.cleanup_confirmation == :unconfirmed,
           "the receipt claims confirmed cleanup while this job's open authority remains"

    assert receipt.outcome == :outcome_unknown

    assert {:ok, retained} = Local.receipt(executor, job_id)
    assert retained.cleanup_confirmation == :unconfirmed
    assert retained.outcome == :outcome_unknown
  end

  # F6
  test "every retention phase of one settlement draws on one shared allowance" do
    # Concept: a settlement has one retention allowance, and each phase spends
    # what is left of it rather than a fresh copy.
    #
    # Technical depth: ADR 0016 gives receipt preparation, optional artifact
    # retention, publication, handoff, and open-entry removal one monotonic
    # deadline that no phase refreshes. Deriving a new wait per phase lets the
    # sequence run for the sum of the phases.
    root = workspace()
    ledger = ledger_root()
    full = String.duplicate("spill-line\n", 2_000)
    File.write!(Path.join(root, "spill.txt"), full)
    {:ok, store} = SlowStore.start(2_000)

    {executor, lease_id} =
      executor_on(root, ledger,
        cleanup_grace_ms: 1_200,
        artifacts: %{module: SlowStore, handle: store}
      )

    {ms, result} =
      elapsed(fn ->
        run(root, "loopex.read", %{"path" => "spill.txt"}, %{
          executor: executor,
          lease_id: lease_id,
          cleanup_grace_ms: 1_200,
          resource_budgets: %{"max_output_bytes" => 256}
        })
      end)

    assert {:ok, receipt} = result
    assert receipt.receipt_retention_bound_ms == 300

    assert receipt.artifacts == [],
           "artifact retention outlived the settlement's whole retention allowance"

    assert ms < 1_500,
           "the settlement spent #{ms}ms against a #{receipt.receipt_retention_bound_ms}ms " <>
             "allowance, so its phases each took one of their own"
  end

  # F7
  test "an admission interrupted after its first durable publication is visible to the scan" do
    # Concept: a half-published admission must leave truth the quarantine scan
    # reads, not truth only the join path reads.
    #
    # Technical depth: publishing the marker first leaves a marker with no open
    # entry when a crash lands between them. The scan reads open entries, so it
    # sees nothing to reconcile, while every later request for that identity
    # joins an operation that will never produce a receipt.
    root = workspace()
    ledger = ledger_root()
    identity = "executor-local"
    assert {:ok, prepared} = Local.prepare_placement(ledger, identity, 2_000)

    interrupted = %{
      job_id: "interrupted-#{System.unique_integer([:positive])}",
      canonical_request_digest: String.duplicate("a", 64),
      operation_id: "interrupted-operation",
      attempt: 1,
      cleanup_grace_ms: 2_000,
      origin_executor_epoch: 3
    }

    markers = Path.join(ledger, "markers")
    File.chmod!(markers, 0o500)
    on_exit(fn -> File.chmod(markers, 0o700) end)

    assert {:error, _reason} =
             Ledger.admit(
               prepared,
               Ledger.marker(interrupted),
               Ledger.open_entry(interrupted, identity)
             )

    File.chmod!(markers, 0o700)

    {executor, lease_id} = executor_on(root, ledger, cleanup_grace_ms: 2_000)

    assert {:error, {:reconciliation_required, 1}} =
             run(root, "loopex.write", %{"path" => "after.txt", "content" => "x"}, %{
               executor: executor,
               lease_id: lease_id,
               cleanup_grace_ms: 2_000
             }),
           "an interrupted admission left no truth the quarantine scan could see"

    source = File.read!(Path.expand("../lib/ledger.ex", __DIR__))

    assert source =~ ~r/defp mkdir_synced\(/,
           "the ledger's created directories are not synced into their parents"
  end

  # F13
  test "the accepted maximum cleanup period never reaches a raw VM timer" do
    # Concept: an admitted period is a duration, and a duration larger than a VM
    # timer accepts must be spent in slices rather than raise.
    #
    # Technical depth: ADR 0016 admits 1..2^64-1 and states that timer
    # implementation limits do not silently cap it. A `receive ... after` above
    # 2^32-1 raises `:timeout_value`, which this executor turns into a
    # non-answer: every confirmation fails and every cancellation of a starting
    # job crashes its caller.
    table = :ets.new(:hotfix_starting_cancel, [:set, :public])
    parent = self()

    worker =
      spawn(fn ->
        Process.put(:loopex_inflight_table, table)
        Process.put(:loopex_cleanup_grace_ms, @max_uint64)
        send(parent, {:hotfix_worker, self()})

        receive do
          {:loopex_cancel_pending, token, from, _grace, _probe} ->
            Process.sleep(150)
            send(from, {:loopex_cancel_result, token, {:ok, :cleaned}})
        end
      end)

    assert_receive {:hotfix_worker, ^worker}, 1_000
    true = :ets.insert(table, {"max-grace-job", {:starting, worker}})

    assert Local.cancel(worker, "max-grace-job") == {:ok, :cleaned},
           "cancelling a starting job under the accepted maximum period did not answer"

    :ets.delete(table)

    assert {"answered\n", 0} =
             Local.answer_within("/bin/sh", ["-c", "sleep 0.05; echo answered"], @max_uint64),
           "a cleanup program bounded by the accepted maximum period reported no answer"
  end

  defp run(root, tool_id, arguments, overrides) do
    {overrides, {executor, lease_id}} =
      case overrides do
        %{executor: executor, lease_id: lease_id} ->
          {Map.drop(overrides, [:executor, :lease_id]), {executor, lease_id}}

        _fresh ->
          {overrides, executor_with(root, [])}
      end

    unique = System.unique_integer([:positive])

    fields =
      Map.merge(
        %{
          protocol_version: 1,
          job_id: "job-#{unique}",
          operation_id: "operation-#{unique}",
          attempt: 1,
          session_id: "s1",
          run_id: "r1",
          turn_id: "t1",
          tool_call_id: "c#{unique}",
          origin_session_epoch: 1,
          origin_executor_epoch: 3,
          executor_identity: "executor-local",
          required_capabilities: ["process"],
          tool_id: tool_id,
          tool_version: "1.0.0",
          effect_class: effect_class_of(tool_id),
          validated_arguments: arguments,
          workspace_ref: "workspace",
          workspace_lease: lease_id,
          run_deadline: System.system_time(:millisecond) + 60_000,
          resource_budgets: %{"max_output_bytes" => 65_536},
          idempotency_class: "never_blind_retry",
          fencing_token: @fence,
          artifact_policy: %{"retain" => true},
          output_policy: %{"capture" => true}
        },
        overrides
      )

    {:ok, job} = Loopex.Executor.job(fields)

    {:ok, grant} =
      Loopex.Executor.issue_grant(
        {:host_policy, :allow},
        job,
        System.system_time(:millisecond) + 60_000
      )

    Local.execute(executor, job, grant, [], Loopex.Executor.discard_progress())
  end

  defp effect_class_of("loopex.read"), do: "read_only"
  defp effect_class_of("loopex.bash"), do: "process"
  defp effect_class_of(_tool_id), do: "workspace_write"

  defp executor_with(root, extra), do: executor_on(root, ledger_root(), extra)

  defp executor_on(root, ledger, extra) do
    lease_id = "lease-#{System.unique_integer([:positive])}"
    {:ok, lease} = WorkspaceLease.start_link(id: lease_id, path: root, fencing_token: @fence)

    {:ok, executor} =
      Local.start_link(
        [
          identity: "executor-local",
          epoch: 3,
          fencing_token: @fence,
          workspace_leases: %{lease_id => lease},
          ledger_root: ledger
        ] ++ extra
      )

    {executor, lease_id}
  end

  defp ledger_root do
    ledger = temporary_root("hotfix-ledger")
    on_exit(fn -> File.rm_rf(ledger) end)
    ledger
  end

  defp workspace do
    root = temporary_root("hotfix-workspace")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  defp temporary_root(prefix),
    do: Path.join(System.tmp_dir!(), "loopex-#{prefix}-#{System.unique_integer([:positive])}")

  defp stubborn_group_command,
    do: "( trap \"\" TERM; sleep 20 ) >/dev/null 2>&1 & printf started; exit 0"

  defp wait_for_file(path, attempts \\ 200) do
    Enum.reduce_while(1..attempts, false, fn _attempt, _acc ->
      if File.exists?(path) do
        {:halt, true}
      else
        Process.sleep(25)
        {:cont, false}
      end
    end)
  end

  defp elapsed(work) do
    started = System.monotonic_time(:millisecond)
    result = work.()
    {System.monotonic_time(:millisecond) - started, result}
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
