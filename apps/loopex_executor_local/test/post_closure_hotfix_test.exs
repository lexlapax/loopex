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

      # The two instances answer a receipt lookup differently for the same job:
      # the owner holds it, the peer sees only an entry no receipt has settled.
      assert {:error, :effect_in_flight} = Local.receipt(owner, job_id)
      assert {:error, :effect_unresolved} = Local.receipt(peer, job_id)

      assert Local.cancel(peer, job_id) == {:ok, :unconfirmed},
             "an instance with no local record of a job open on its own root reported it cleaned"

      # ADR 0016 clause 4: "An absent ID has no request digest and answers
      # unconfirmed without durable cancellation state." This assertion read
      # `{:ok, :cleaned}` and locked the opposite. A readable root that holds no
      # entry for an identity is not proof that that identity's effect is over:
      # it is equally the root of a job admitted somewhere this instance cannot
      # see, of a job whose request digest nothing here can bind, and of a job
      # that never existed. `cleaned` is reserved for a matching durable refusal
      # or an independently confirmed cleanup, and an absent ID produces
      # neither.
      assert Local.cancel(peer, "absent-#{System.unique_integer([:positive])}") ==
               {:ok, :unconfirmed}
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
    ledger = ledger_root()

    {executor, lease_id} =
      executor_on(root, ledger, cleanup_grace_ms: 20_000)

    assert {:ok, prepared} =
             Local.prepare_placement(ledger, "executor-local", 20_000)

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

      parent = self()

      claim_holder =
        spawn(fn ->
          Ledger.with_claim(prepared, fn ->
            send(parent, {:cancellation_root_claim_held, self()})

            receive do
              :release_cancellation_root_claim -> :ok
            end
          end)
        end)

      on_exit(fn ->
        if Process.alive?(claim_holder), do: send(claim_holder, :release_cancellation_root_claim)
      end)

      assert_receive {:cancellation_root_claim_held, ^claim_holder}, 2_000
      {ms, answer} = elapsed(fn -> Local.cancel(executor, job_id) end)

      send(claim_holder, :release_cancellation_root_claim)

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

  # H3
  test "a peer never receives a final receipt while open-authority disposal remains unsettled" do
    # Concept: publishing this job's terminal truth and disposing of its open
    # authority are one decision, so nothing a reader can see is allowed to
    # reverse afterwards.
    #
    # Technical depth: ADR 0016 clause 7 requires every terminal-plus-open
    # decision to acquire the root-wide claim, read one complete bounded snapshot
    # while mutation is excluded, and fix its answer before releasing it. The
    # settlement retains the confirmed receipt and removes the entry under one
    # claim. A removal that fails preserves those operation and cleanup facts but
    # leaves the open entry as the quarantine. This case forces the failure through the
    # unlink seam -- the claim itself stays available, so the settlement really
    # does publish a confirmed receipt -- and polls a
    # peer instance across the whole window. The peer holds no claim of its own
    # over those bytes, so what protects it is the reader rule rather than the
    # writer: while this job's open entry stands, a retained receipt is
    # `effect_settling` and never a terminal answer, so no reader could have
    # consumed the confirmed form as final. The immediate caller is refused a
    # final answer for the same reason.
    root = workspace()
    ledger = ledger_root()

    refuse_removal = fn _prepared, _job_id -> {:error, :removal_refused_by_case} end

    {owner, owner_lease} =
      executor_on(root, ledger, cleanup_grace_ms: 8_000, open_authority_close: refuse_removal)

    {peer, _peer_lease} = executor_on(root, ledger, cleanup_grace_ms: 8_000)

    ready = Path.join(root, "publication-ready")
    job_id = "publication-#{System.unique_integer([:positive])}"

    running =
      Task.async(fn ->
        run(root, "loopex.bash", %{"command" => "printf ready > #{ready}; sleep 1"}, %{
          executor: owner,
          lease_id: owner_lease,
          job_id: job_id,
          cleanup_grace_ms: 8_000
        })
      end)

    assert wait_for_file(ready), "the command never started"

    polling = Task.async(fn -> poll_receipt(peer, job_id, []) end)

    assert {:error, {:effect_settling, {:open_authority_not_removed, :removal_refused_by_case}}} =
             Task.await(running, 30_000)

    receipt = retained_receipt!(ledger, job_id)
    send(polling.pid, :stop)
    observations = Task.await(polling, 10_000)

    assert receipt.cleanup_confirmation == :confirmed
    assert receipt.outcome == :completed

    assert File.regular?(Path.join([ledger, "open", digest(job_id)])),
           "the open entry was removed although the removal failed"

    # The poller's last read happens after the settlement returned, so the
    # retained receipt is on the root by then: an empty list would mean this case
    # watched nothing.
    assert observations != [],
           "the peer never answered this job's lookup at all, so nothing was observed"

    assert List.last(observations) == {:error, :effect_settling},
           "after a settlement that ended quarantined the peer answered " <>
             "#{inspect(List.last(observations))} rather than an unresolved effect"

    leaked_terminal =
      Enum.filter(observations, fn
        {outcome, confirmation} when is_atom(outcome) and is_atom(confirmation) ->
          outcome == :completed or confirmation == :confirmed

        _unresolved ->
          false
      end)

    assert leaked_terminal == [],
           "a peer read #{length(leaked_terminal)} terminal receipt(s) while the operation's " <>
             "open authority still made settlement unresolved"
  end

  test "receipt lookup refuses every malformed member of the complete open-authority snapshot" do
    # Concept: one valid terminal cannot hide malformed authority elsewhere on
    # the same trusted root, and a non-record at its own open identity is not
    # absence.
    #
    # Technical depth: receipt lookup once reduced the open plane to
    # `File.regular?(target)`. A directory at this job's open path therefore made
    # a retained completion look final, while a malformed unrelated tail was not
    # read at all. Produce one real final receipt, then drive both shapes. The
    # decision must validate one complete bounded snapshot under the root claim
    # before returning that receipt.
    root = workspace()
    ledger = ledger_root()
    {executor, lease_id} = executor_on(root, ledger, cleanup_grace_ms: 2_000)
    job_id = "complete-snapshot-#{System.unique_integer([:positive])}"

    assert {:ok, retained} =
             run(root, "loopex.write", %{"path" => "snapshot.txt", "content" => "complete"}, %{
               executor: executor,
               lease_id: lease_id,
               job_id: job_id,
               cleanup_grace_ms: 2_000
             })

    assert retained.outcome == :completed
    open_directory = Path.join(ledger, "open")
    own_open = Path.join(open_directory, digest(job_id))
    File.mkdir!(own_open)

    assert {:error, {:ledger_unavailable, _reason}} = Local.receipt(executor, job_id)

    File.rmdir!(own_open)
    unrelated_open = Path.join(open_directory, digest("unrelated-malformed-open"))
    File.write!(unrelated_open, "not a canonical open-authority record")

    assert {:error, {:ledger_unavailable, _reason}} = Local.receipt(executor, job_id)
  end

  test "a failed close after durable unlink restores the warning without rewriting receipt facts" do
    # Concept: losing the open entry is not proof that its effect settled. A
    # close operation that removed the entry but failed before it could report a
    # complete close must leave an equivalent root-wide warning behind.
    #
    # Technical depth: the close seam below removes the exact open entry, syncs
    # the directory that names it, and only then reports failure. That is the
    # strongest partial-removal state: the deletion itself is durable, so merely
    # leaving only the receipt produces a receipt with no open entry. The read side
    # then mistakes those bytes for final and the
    # admission scan sees a clean root. The repair must restore the same open
    # record before releasing the root claim (or retain that claim if it cannot),
    # so neither this receipt nor an unrelated effect can cross the ambiguity.
    root = workspace()
    ledger = ledger_root()
    parent = self()
    job_id = "partial-close-#{System.unique_integer([:positive])}"
    open_path = Path.join([ledger, "open", digest(job_id)])

    partial_close = fn _prepared, ^job_id ->
      :ok = File.rm(open_path)
      :ok = sync_directory(Path.dirname(open_path))
      send(parent, {:durably_unlinked, job_id})
      {:error, :close_failed_after_durable_unlink}
    end

    {executor, lease_id} =
      executor_on(root, ledger,
        cleanup_grace_ms: 2_000,
        open_authority_close: partial_close
      )

    assert {:error,
            {:effect_settling, {:open_authority_not_removed, :close_failed_after_durable_unlink}}} =
             run(root, "loopex.write", %{"path" => "first.txt", "content" => "once"}, %{
               executor: executor,
               lease_id: lease_id,
               job_id: job_id,
               cleanup_grace_ms: 2_000
             })

    assert_receive {:durably_unlinked, ^job_id}, 1_000
    receipt = retained_receipt!(ledger, job_id)
    assert receipt.outcome == :completed
    assert receipt.cleanup_confirmation == :confirmed

    assert {:error, {:reconciliation_required, 1}} =
             run(root, "loopex.write", %{"path" => "unrelated.txt", "content" => "forbidden"}, %{
               executor: executor,
               lease_id: lease_id,
               job_id: "after-partial-close-#{System.unique_integer([:positive])}",
               cleanup_grace_ms: 2_000
             })

    refute File.exists?(Path.join(root, "unrelated.txt")),
           "an unrelated effect was admitted after the root lost its quarantine warning"

    assert File.regular?(open_path),
           "the failed close durably removed the only root warning for this unresolved effect"

    assert Local.receipt(executor, job_id) == {:error, :effect_settling},
           "the proved receipt became final although the restored open warning remains"
  end

  test "a failed close whose open authority cannot be restored retains the root claim" do
    # Concept: if neither the close nor restoration of its warning can be
    # proved, the administrative claim itself becomes the fail-closed warning.
    #
    # Technical depth: the close removes and syncs the exact open path, then
    # replaces that path with a directory before reporting failure. Restoration
    # must refuse the non-regular path. Releasing the surrounding root claim in
    # that state would leave later work free to interpret the missing record as
    # permission, so the exact restoration failure must retain the claim and
    # every later effect must stop there.
    root = workspace()
    ledger = ledger_root()
    job_id = "restore-failure-#{System.unique_integer([:positive])}"
    open_path = Path.join([ledger, "open", digest(job_id)])

    unrestorable_close = fn _prepared, ^job_id ->
      :ok = File.rm(open_path)
      :ok = sync_directory(Path.dirname(open_path))
      :ok = File.mkdir(open_path)
      {:error, :close_failed_after_durable_unlink}
    end

    {executor, lease_id} =
      executor_on(root, ledger,
        cleanup_grace_ms: 2_000,
        open_authority_close: unrestorable_close
      )

    assert {:error,
            {:receipt_not_retained,
             {:ledger_unavailable,
              {:root_claim_retained,
               {:open_authority_not_restored, :close_failed_after_durable_unlink,
                {:ledger_unavailable, :record_not_a_regular_file}}}}}} =
             run(root, "loopex.write", %{"path" => "first.txt", "content" => "once"}, %{
               executor: executor,
               lease_id: lease_id,
               job_id: job_id,
               cleanup_grace_ms: 2_000
             })

    assert File.dir?(Path.join(ledger, "claim")),
           "the root claim was released after both close and restoration were unproved"

    assert {:error, {:ledger_unavailable, :root_claim_held}} =
             run(root, "loopex.write", %{"path" => "unrelated.txt", "content" => "forbidden"}, %{
               executor: executor,
               lease_id: lease_id,
               job_id: "after-restore-failure-#{System.unique_integer([:positive])}",
               run_deadline: System.system_time(:millisecond) + 250,
               cleanup_grace_ms: 2_000
             })

    refute File.exists?(Path.join(root, "unrelated.txt"))
  end

  test "an unconfirmed administrative worker retains the root claim by construction" do
    # Concept: a worker that may still mutate the ledger is itself a quarantine
    # fact. Releasing the administrative claim would turn uncertainty into
    # permission for an unrelated effect.
    #
    # Technical depth: an untrappable BEAM kill normally confirms immediately,
    # so scheduling a real process that reliably survives the fixed confirmation
    # interval is not a deterministic test boundary. These assertions therefore
    # name their structural scope explicitly: every receipt-writer and open-entry
    # removal branch maps a failed confirmation to `:unconfirmed`, and both outer
    # settlement branches convert that exact result into the Ledger's deliberate
    # retain-claim sentinel. The behavioral sibling above proves the sentinel
    # actually strands the root when reached.
    source = File.read!(Path.expand("../lib/executor.ex", __DIR__))

    assert source =~
             ~r/\{:guardian_stopped, reason, false\} ->\s+\{:unconfirmed,\s+\{:ledger_unavailable, \{:open_authority_removal_guardian_unconfirmed, reason\}\}\}/s,
           "an unconfirmed open-entry removal became an ordinary releasable error"

    assert length(
             Regex.scan(
               ~r/\{:guardian_stopped, reason, false\} ->\s+\{:unconfirmed, \{:receipt_retention_guardian_unconfirmed, reason\}\}/s,
               source
             )
           ) == 2,
           "not every receipt writer preserves failed stop confirmation as unconfirmed"

    assert source =~
             ~r/\{:unconfirmed, reason\} ->\s+Ledger\.retain_claim\(\{:receipt_retention_unconfirmed, reason\}\)/s,
           "unconfirmed receipt retention no longer retains the root claim"

    assert source =~
             ~r/\{:unconfirmed, close_reason\} ->\s+Ledger\.retain_claim\(\{:open_authority_close_unconfirmed, close_reason\}\)/s,
           "unconfirmed open-entry removal no longer retains the root claim"
  end

  # F5
  test "a settlement that cannot remove its open record preserves proved facts but returns no final" do
    # Concept: an administrative failure cannot falsify the operation or cleanup,
    # and it cannot expose provisional receipt bytes as a final answer either.
    #
    # Technical depth: ADR 0016 removes an open entry only under exact authority
    # proof and quarantines the root while one is unresolved. Discarding the
    # removal's result hands a caller success while every later effect on that
    # root is refused for reconciliation. Rewriting the receipt instead erases
    # facts already proved by the effect boundary. The removal is failed here
    # through the unlink seam rather than by holding the claim, so this proves all
    # three facts independently: preserved bytes, unresolved return, and open root.
    root = workspace()
    ledger = ledger_root()

    refuse_removal = fn _prepared, _job_id -> {:error, :removal_refused_by_case} end

    {executor, lease_id} =
      executor_on(root, ledger, cleanup_grace_ms: 2_000, open_authority_close: refuse_removal)

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

    assert {:error, {:effect_settling, {:open_authority_not_removed, :removal_refused_by_case}}} =
             Task.await(running, 30_000)

    receipt = retained_receipt!(ledger, job_id)

    assert File.regular?(Path.join([ledger, "open", digest(job_id)])),
           "the open entry was removed although the removal failed"

    assert receipt.cleanup_confirmation == :confirmed
    assert receipt.outcome == :completed

    # The durable bytes are proved but provisional while the entry they belong to
    # remains: a reader is told settlement is unresolved rather than handed a
    # terminal it could act on.
    assert Local.receipt(executor, job_id) == {:error, :effect_settling}
  end

  # H4
  test "open-entry removal spends the settlement's remaining allowance and ends inside it" do
    # Concept: removing this job's open authority is a phase of the same
    # settlement the receipt is, so it spends what that settlement has left
    # rather than nothing and rather than however long the filesystem takes.
    #
    # Technical depth: ADR 0016 clause 6 gives receipt preparation, artifact
    # retention, publication, lease-loss handoff, sync recovery and open-entry
    # removal one monotonic deadline that no phase refreshes. The removal had no
    # bound of any kind: the unlink and parent sync inside the claim could block
    # for as long as the filesystem liked with no allowance to answer to. No
    # filesystem call can be made slow on demand, so the unlink is driven through
    # the seam and blocks for five seconds against a two-second allowance whose
    # removal share is one second. The settlement must abandon it at that share
    # and leave time to preserve its open warning, so removing the
    # outer bound turns this case red rather than merely slow.
    root = workspace()
    ledger = ledger_root()

    blocked_removal = fn _prepared, _job_id ->
      Process.sleep(5_000)
      :ok
    end

    {executor, lease_id} =
      executor_on(root, ledger, cleanup_grace_ms: 8_000, open_authority_close: blocked_removal)

    ready = Path.join(root, "bounded-removal-ready")
    job_id = "bounded-removal-#{System.unique_integer([:positive])}"

    {ms, settled} =
      elapsed(fn ->
        run(root, "loopex.bash", %{"command" => "printf ready > #{ready}; sleep 1"}, %{
          executor: executor,
          lease_id: lease_id,
          job_id: job_id,
          cleanup_grace_ms: 8_000
        })
      end)

    assert {:error, {:effect_settling, {:open_authority_not_removed, _reason}}} = settled
    receipt = retained_receipt!(ledger, job_id)

    # The committed period's quarter is the whole settlement's allowance, and the
    # removal takes a share of what is left of it so that the phase writing down
    # what happened is never starved by the phase clearing the root.
    assert receipt.receipt_retention_bound_ms == 2_000

    assert receipt.cleanup_confirmation == :confirmed
    assert receipt.outcome == :completed

    assert File.regular?(Path.join([ledger, "open", digest(job_id)])),
           "the open entry was reported removed by an unlink that never answered"

    assert ms >= 1_600,
           "the job slept a second and its settlement returned after #{ms}ms, so the removal " <>
             "spent none of the allowance waiting for the unlink"

    assert ms < 5_000,
           "the settlement took #{ms}ms against a #{receipt.receipt_retention_bound_ms}ms " <>
             "allowance and a five-second unlink, so the unlink was not bounded by it"
  end

  # B3
  test "a settlement whose receipt cannot be retained leaves this job's open authority" do
    # Concept: the warning to the next executor on this root is the open entry,
    # and a settlement that could not write down what happened must not remove it.
    #
    # Technical depth: the removal used to run before the receipt was retained, so
    # a removal that succeeded followed by a write, rename, or sync that failed
    # left the root holding neither an open entry nor a receipt. Nothing then
    # said the effect was unresolved: a later reader got `:absent`, and the next
    # admission on that root was accepted rather than refused, which is exactly
    # ADR 0016 clause 6 and 7's quarantine being lost. The receipt is now written
    # first and the entry removed second, so a failed retention leaves the entry
    # where it is. The rename is failed by putting a directory where the receipt
    # belongs, after admission so that the reservation still reads a clean root.
    root = workspace()
    ledger = ledger_root()
    {executor, lease_id} = executor_on(root, ledger, cleanup_grace_ms: 2_000)
    ready = Path.join(root, "retention-failure-ready")
    job_id = "retention-failure-#{System.unique_integer([:positive])}"

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

    obstruction = Path.join(ledger, digest(job_id) <> ".receipt")
    on_exit(fn -> File.rm_rf(obstruction) end)
    assert :ok = File.mkdir_p(obstruction)

    assert {:error, {:receipt_not_retained, _reason}} = Task.await(running, 30_000),
           "a settlement that could not write its receipt reported a receipt"

    assert File.regular?(Path.join([ledger, "open", digest(job_id)])),
           "the open entry was removed by a settlement that never wrote a receipt, so this " <>
             "root carries neither a terminal nor a warning about the effect that ran on it"

    # The standing warning is what the next executor on this root has to see: an
    # unresolved entry refuses new effects rather than admitting them beside an
    # effect nothing resolved.
    assert {:error, {:reconciliation_required, 1}} =
             run(root, "loopex.read", %{"path" => "."}, %{
               executor: executor,
               lease_id: lease_id,
               job_id: "after-#{System.unique_integer([:positive])}",
               cleanup_grace_ms: 2_000
             })
  end

  # B3
  test "a settlement that cannot take the root claim leaves the open entry and reports it" do
    # Concept: the claim is how this settlement excludes every other writer and
    # reader from the pair of facts it is about to change, so a settlement that
    # cannot take it publishes nothing at all.
    #
    # Technical depth: the claim is taken once for the whole settlement and waited
    # for out of the same allowance the writes spend, capped at a share of it so
    # that taking the claim can never consume what writing under it needs. A claim
    # that never arrives is a failed retention, which is the safe direction: the
    # open entry stays, the root stays quarantined, and the caller is told
    # `{:receipt_not_retained, {:ledger_unavailable, :root_claim_held}}` rather
    # than being handed a terminal decided outside the claim.
    root = workspace()
    ledger = ledger_root()
    {executor, lease_id} = executor_on(root, ledger, cleanup_grace_ms: 8_000)
    ready = Path.join(root, "claim-held-ready")
    job_id = "claim-held-#{System.unique_integer([:positive])}"

    running =
      Task.async(fn ->
        elapsed(fn ->
          run(root, "loopex.bash", %{"command" => "printf ready > #{ready}; sleep 1"}, %{
            executor: executor,
            lease_id: lease_id,
            job_id: job_id,
            cleanup_grace_ms: 8_000
          })
        end)
      end)

    # The claim is taken after admission, because admission takes it too: a claim
    # held before the job starts refuses the effect rather than its settlement.
    assert wait_for_file(ready), "the command never started"

    claim = Path.join(ledger, "claim")
    on_exit(fn -> File.rmdir(claim) end)
    assert :ok = File.mkdir(claim)

    assert {ms, settled} = Task.await(running, 30_000)

    assert settled == {:error, {:receipt_not_retained, {:ledger_unavailable, :root_claim_held}}}

    assert File.regular?(Path.join([ledger, "open", digest(job_id)])),
           "the open entry was removed while the root claim was held"

    assert ms >= 1_600,
           "the job slept a second and its settlement returned after #{ms}ms, so it spent " <>
             "none of the allowance waiting for the claim it could not take"

    assert ms < 5_000,
           "the settlement took #{ms}ms against a 2000ms allowance, so waiting for the claim " <>
             "was not bounded by it"
  end

  # B3
  test "a settlement that removes its open entry ends with a final receipt and no entry" do
    # Concept: the ordinary end of a settlement is one final terminal on a root
    # with nothing left open on it.
    #
    # Technical depth: the reader rule that makes a receipt final only once its
    # open entry is gone has to leave the ordinary path exactly where it was, or
    # every recovering coordinator would be told `effect_settling` forever. The
    # settlement retains the receipt and removes the entry under one claim, so
    # when it returns both halves of the answer are already true: the entry is
    # gone, the bytes are the confirmed ones, and a later lookup is the final
    # `{:ok, receipt}` rather than an unresolved effect. The root is clean enough
    # to admit the next job, which is the other half of the quarantine claim.
    root = workspace()
    ledger = ledger_root()
    {executor, lease_id} = executor_on(root, ledger, cleanup_grace_ms: 2_000)
    job_id = "settled-#{System.unique_integer([:positive])}"

    assert {:ok, receipt} =
             run(root, "loopex.bash", %{"command" => "printf done"}, %{
               executor: executor,
               lease_id: lease_id,
               job_id: job_id,
               cleanup_grace_ms: 2_000
             })

    assert receipt.cleanup_confirmation == :confirmed

    refute File.exists?(Path.join([ledger, "open", digest(job_id)])),
           "a settled job left its open authority on the root"

    assert {:ok, retained} = Local.receipt(executor, job_id)
    assert retained.job_id == job_id
    assert retained.cleanup_confirmation == :confirmed

    assert {:ok, _next} =
             run(root, "loopex.bash", %{"command" => "printf again"}, %{
               executor: executor,
               lease_id: lease_id,
               job_id: "after-#{System.unique_integer([:positive])}",
               cleanup_grace_ms: 2_000
             })
  end

  # H5
  test "a root claim that cannot be released after a raising body reaches the caller" do
    # Concept: giving the claim back is part of taking it on the exceptional path
    # too, so a release that did not happen travels with the exception.
    #
    # Technical depth: the normal path replaces the body's result with
    # `{:ledger_unavailable, {:root_claim_not_released, reason}}`; the exceptional
    # path discarded the release result entirely, so a body that raised on a root
    # it then stranded reported only the raise and every later claim answered
    # `root_claim_held` with nothing having said why. Converting the exception
    # into that error instead would surface the strand and lose the fault, so the
    # original kind and stacktrace are kept and the reason carries both facts.
    ledger = ledger_root()
    assert {:ok, prepared} = Local.prepare_placement(ledger, "executor-local", 2_000)

    claim = Path.join(ledger, "claim")
    stray = Path.join(claim, "late-writer")
    on_exit(fn -> File.rm(stray) end)

    raised =
      try do
        Ledger.with_claim(prepared, fn ->
          File.write!(stray, "a byte a late writer left inside the claim")
          raise "the body failed on a root it also stranded"
        end)
      rescue
        error -> error
      end

    assert %ErlangError{original: {:root_claim_not_released, _release, original}} = raised,
           "a body that raised on a stranded root reported only the raise"

    assert %RuntimeError{message: "the body failed on a root it also stranded"} = original,
           "the fault the body raised was replaced rather than carried"

    # Stranded, and honestly so: the reason above is the only warning anyone gets
    # that this root now refuses every claim until an operator clears it.
    assert File.dir?(claim), "the claim was reported unreleasable but is gone"

    assert Ledger.with_claim(prepared, fn -> :ok end) ==
             {:error, {:ledger_unavailable, :root_claim_held}}
  end

  # H5
  test "a claim released after a raising body re-raises exactly what the body raised" do
    # Concept: the ordinary exceptional path is unchanged, so a body that fails on
    # a healthy root fails the way it always did.
    #
    # Technical depth: only a release that fails changes what the caller sees.
    # Where the claim comes back, the original kind, reason, and stacktrace are
    # re-raised untouched, which is what keeps a defect in a body diagnosable
    # rather than reported as a ledger fault.
    ledger = ledger_root()
    assert {:ok, prepared} = Local.prepare_placement(ledger, "executor-local", 2_000)

    assert_raise RuntimeError, "an ordinary body failure", fn ->
      Ledger.with_claim(prepared, fn -> raise "an ordinary body failure" end)
    end

    refute File.dir?(Path.join(ledger, "claim")),
           "a body that raised on a healthy root left the claim behind"

    assert Ledger.with_claim(prepared, fn -> :ok end) == :ok
  end

  # F6
  test "the retention episode opens before receipt preparation on both effect paths" do
    # Concept: receipt preparation is settlement work and spends the same one
    # allowance as artifact retention, publication, and authority disposal.
    #
    # Technical depth: opening the episode lazily inside `spill/5` or
    # `settle_receipt/4` leaves ordinary replies free to spend unbounded
    # preparation time before the clock exists. Both production `run_tool`
    # clauses therefore open it immediately after the effect result and before
    # their first normalization/spill or receipt construction. The exact
    # ordering assertion kills either one-sided deletion and moving the opening
    # after preparation, while the behavioural sibling below proves later phases
    # reuse rather than refresh that instant.
    source = File.read!(Path.expand("../lib/executor.ex", __DIR__))

    [_before, coding_clause, demonstration_and_rest] =
      String.split(source, "  defp run_tool(", parts: 3)

    [demonstration_clause | _rest] =
      String.split(demonstration_and_rest, "\n  defp progress_identity", parts: 2)

    assert_ordered = fn clause, labels ->
      offsets =
        Enum.map(labels, fn label ->
          case :binary.match(clause, label) do
            {offset, _size} -> offset
            :nomatch -> flunk("run_tool clause is missing #{inspect(label)}")
          end
        end)

      assert offsets == Enum.sort(offsets),
             "run_tool settlement order changed for #{inspect(labels)}: #{inspect(offsets)}"
    end

    assert_ordered.(coding_clause, [
      "      run_coding_tool(",
      "    _retention_deadline = retention_until()",
      "      spill(",
      "    receipt("
    ])

    assert_ordered.(demonstration_clause, [
      "      run_owned_process(",
      "    _retention_deadline = retention_until()",
      "    {outcome, output, _complete} = normalize_tool_result(tool_result)",
      "    receipt("
    ])
  end

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

    # This case used to close by reading `../lib/ledger.ex` and asserting that
    # the text `defp mkdir_synced(` appeared in it. That is not a test of
    # anything: it passes for any body whatsoever, including the `File.mkdir_p/1`
    # body that synced only the deepest parent, and it fails for a correct
    # implementation that renames the function. The behaviour it was standing in
    # for is proved directly by "every ledger directory level is created and
    # synced into the parent that names it" below, which observes the syscalls.
  end

  # H6
  test "every ledger directory level is created and synced into the parent that names it" do
    # Concept: a directory this ledger created is not durable until the directory
    # that names it is, and that is true of every level it created, not only the
    # last one.
    #
    # Technical depth: `ledger.ex` promises that "each directory this creates is
    # synced into the directory that names it, so a crash cannot leave a record
    # durable inside a directory that is not". `File.mkdir_p/1` creates as many
    # components as are missing and returns once the kernel holds the entries,
    # and only the deepest parent was synced afterwards. For an absent
    # `<base>/a/b/c` neither `<base>` nor `<base>/a` was ever synced, so a crash
    # could lose the whole subtree with the generation record durable inside it.
    # `:erlang.trace_pattern/3` over `:file.make_dir/1` and `:file.sync/1` is what
    # observes the ordering; the artifact store's `ensure_directory/2` proves the
    # same property the same way.
    base = temporary_root("hotfix-nested")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)

    levels = [
      Path.join(base, "a"),
      Path.join([base, "a", "b"]),
      Path.join([base, "a", "b", "c"])
    ]

    assert :erlang.trace_pattern({:file, :make_dir, 1}, true, [:local]) == 1
    assert :erlang.trace_pattern({:file, :sync, 1}, true, [:local]) == 1

    assert :erlang.trace_pattern(
             {:file, :open, 2},
             [{:_, [], [{:return_trace}]}],
             [:local]
           ) == 1

    on_exit(fn ->
      _ = :erlang.trace_pattern({:file, :make_dir, 1}, false, [:local])
      _ = :erlang.trace_pattern({:file, :sync, 1}, false, [:local])
      _ = :erlang.trace_pattern({:file, :open, 2}, false, [:local])
    end)

    parent = self()

    {preparer, monitor} =
      spawn_monitor(fn ->
        :erlang.trace(self(), true, [:call, :set_on_spawn, {:tracer, parent}])

        send(
          parent,
          {:nested_prepared, Local.prepare_placement(List.last(levels), "executor-local", 2_000)}
        )
      end)

    assert_receive {:nested_prepared, preparation}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^preparer, :normal}, 1_000
    assert {:ok, _prepared} = preparation

    events = collect_directory_trace() |> directory_events()

    for level <- levels do
      created = Enum.find_index(events, &(&1 == {:created, level}))
      assert created, "#{level} was never created, so this case observed nothing"

      assert Enum.find_index(
               Enum.drop(events, created + 1),
               &(&1 == {:synced, Path.dirname(level)})
             ),
             "#{level} was created and #{Path.dirname(level)} was never synced after it, so a " <>
               "crash could leave a record durable inside a directory that is not"
    end
  end

  # H5
  test "a root claim that cannot be released reaches the caller instead of the body's answer" do
    # Concept: giving the claim back is part of taking it, so a release that did
    # not happen is part of this call's answer.
    #
    # Technical depth: `with_claim/3` released in an `after` and discarded the
    # result. A non-empty or EIO claim directory therefore returned the body's
    # success while every later claim on that root answered
    # `{:ledger_unavailable, :root_claim_held}` for the life of the root -- ADR
    # 0016 clause 7's bounded ledger-unavailability, delivered to everyone except
    # the caller that caused it.
    ledger = ledger_root()
    assert {:ok, prepared} = Local.prepare_placement(ledger, "executor-local", 2_000)

    claim = Path.join(ledger, "claim")
    stray = Path.join(claim, "late-writer")
    on_exit(fn -> File.rm(stray) end)

    answer =
      Ledger.with_claim(prepared, fn ->
        File.write!(stray, "a byte a late writer left inside the claim")
        :ok
      end)

    assert {:error, {:ledger_unavailable, {:root_claim_not_released, _reason}}} = answer,
           "a body that stranded the root claim was reported as having succeeded"

    # Stranded, and honestly so: the reason above is the only warning anyone gets
    # that this root now refuses every claim until an operator clears it.
    assert File.dir?(claim), "the claim was reported unreleasable but is gone"

    assert Ledger.with_claim(prepared, fn -> :ok end) ==
             {:error, {:ledger_unavailable, :root_claim_held}}
  end

  test "root claim contention never refreshes an absolute settlement deadline" do
    # Concept: waiting for a root claim spends one allowance; it never creates a
    # little more time on every poll.
    #
    # Technical depth: the holder releases after the original instant. A retry
    # loop that increments or reconstructs that instant can acquire and run the
    # body, while the conforming loop has already answered unavailable. The
    # structural assertion closes the narrow scheduler case where a one-
    # millisecond-per-poll mutant happens not to accumulate enough retries during
    # this run; it names the exact recursion edge whose argument is the invariant.
    ledger = ledger_root()
    assert {:ok, prepared} = Local.prepare_placement(ledger, "executor-local", 2_000)
    parent = self()

    holder =
      spawn(fn ->
        Ledger.with_claim(prepared, fn ->
          send(parent, {:absolute_deadline_claim_held, self()})

          receive do
            :release_absolute_deadline_claim -> :ok
          end
        end)
      end)

    on_exit(fn ->
      if Process.alive?(holder), do: send(holder, :release_absolute_deadline_claim)
    end)

    assert_receive {:absolute_deadline_claim_held, ^holder}, 2_000
    deadline = System.monotonic_time(:millisecond) + 1_000

    waiter =
      Task.async(fn ->
        Ledger.with_claim_until(prepared, fn -> :acquired_after_deadline end, deadline)
      end)

    Process.sleep(1_100)
    send(holder, :release_absolute_deadline_claim)

    assert Task.await(waiter, 2_000) ==
             {:error, {:ledger_unavailable, :root_claim_held}}

    parent = self()

    assert Ledger.with_claim_until(
             prepared,
             fn -> send(parent, :expired_claim_body_ran) end,
             System.monotonic_time(:millisecond) - 1
           ) == {:error, {:ledger_unavailable, :root_claim_held}}

    refute_receive :expired_claim_body_ran, 50

    # The ordinary zero-wait API still means one immediate acquisition attempt;
    # its duration bounds contention rather than a body that acquired the claim
    # without waiting.
    assert Ledger.with_claim(prepared, fn -> :immediate_body_ran end, 0) ==
             :immediate_body_ran

    source = File.read!(Path.expand("../lib/ledger.ex", __DIR__))

    assert source =~
             ~r/Process\.sleep\(min\(remaining, @claim_poll_ms\)\)\s+with_claim_until\(prepared, work, deadline\)/s,
           "claim contention no longer recurs with the original absolute deadline"

    assert source =~
             ~r/case revalidate\(prepared\) do\s+:ok ->\s+if work_policy == :initial_attempt or\s+System\.monotonic_time\(:millisecond\) < deadline do\s+work\.\(\)/s,
           "the absolute-deadline API no longer fences the body after claim acquisition"

    assert source =~
             ~r/if\(wait_ms == 0, do: :initial_attempt, else: :deadline_bound\)/,
           "a positive relative wait can bypass the final claim-deadline fence"

    assert source =~
             ~r/def with_claim_until\([^\n]+\n\s+when[^\n]+do\n\s+if System\.monotonic_time\(:millisecond\) < deadline,\n\s+do: do_with_claim_until\(prepared, work, deadline, :deadline_bound\)/,
           "the absolute-deadline entrypoint can bypass its post-acquisition fence"
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
          {:loopex_cancel_pending, token, from, {_until, _grace, _probe}} ->
            Process.sleep(150)
            send(from, {:loopex_cancel_result, token, {:ok, :cleaned}})
        end
      end)

    assert_receive {:hotfix_worker, ^worker}, 1_000

    true =
      :ets.insert(table, [
        {"max-grace-job", {:starting, worker}},
        {{:loopex_process_authority, "max-grace-job"}, worker, @max_uint64}
      ])

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

  defp retained_receipt!(ledger, job_id) do
    ledger
    |> Path.join(digest(job_id) <> ".receipt")
    |> File.read!()
    |> :erlang.binary_to_term([:safe])
  end

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

  defp sync_directory(path) do
    {:ok, directory} = :file.open(String.to_charlist(path), [:raw, :read, :directory])

    try do
      :file.sync(directory)
    after
      :file.close(directory)
    end
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  # Every answer this peer could have taken, in order, with the last one taken
  # after the settlement returned so that the retained receipt is certain to be
  # in the list. Unresolved answers are recorded too: while the settlement holds
  # the claim, and afterwards while this job's open entry stands, they are the
  # only answers there are, and a list that dropped them could not tell watching
  # nothing apart from watching correctly.
  defp poll_receipt(peer, job_id, seen) do
    seen = record_receipt(peer, job_id, seen)

    receive do
      :stop -> Enum.reverse(record_receipt(peer, job_id, seen))
    after
      10 -> poll_receipt(peer, job_id, seen)
    end
  end

  defp record_receipt(peer, job_id, seen) do
    case Local.receipt(peer, job_id) do
      {:ok, retained} -> [{retained.outcome, retained.cleanup_confirmation} | seen]
      other -> [other | seen]
    end
  end

  defp collect_directory_trace(acc \\ []) do
    receive do
      {:trace, _pid, :call, {:file, :make_dir, [_path]}} = event ->
        collect_directory_trace([event | acc])

      {:trace, _pid, :call, {:file, :open, [_path, _modes]}} = event ->
        collect_directory_trace([event | acc])

      {:trace, _pid, :return_from, {:file, :open, 2}, _result} = event ->
        collect_directory_trace([event | acc])

      {:trace, _pid, :call, {:file, :sync, [_device]}} = event ->
        collect_directory_trace([event | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  # `:file.sync/1` names an open device rather than a path, so the open calls are
  # traced with their returns and the device is resolved back to the path it was
  # opened on. The result is the creation and sync events in the order the
  # filesystem saw them, which is what an ordering claim needs.
  defp directory_events(events) do
    {_pending, _devices, ordered} =
      Enum.reduce(events, {%{}, %{}, []}, fn
        {:trace, _pid, :call, {:file, :make_dir, [path]}}, {pending, devices, ordered} ->
          {pending, devices, [{:created, normalize_path(path)} | ordered]}

        {:trace, pid, :call, {:file, :open, [path, _modes]}}, {pending, devices, ordered} ->
          stack = Map.get(pending, pid, [])
          {Map.put(pending, pid, [normalize_path(path) | stack]), devices, ordered}

        {:trace, pid, :return_from, {:file, :open, 2}, {:ok, device}},
        {pending, devices, ordered} ->
          case Map.get(pending, pid, []) do
            [path | rest] ->
              {Map.put(pending, pid, rest), Map.put(devices, device, path), ordered}

            [] ->
              {pending, devices, ordered}
          end

        {:trace, _pid, :call, {:file, :sync, [device]}}, {pending, devices, ordered} ->
          case Map.get(devices, device) do
            nil -> {pending, devices, ordered}
            path -> {pending, devices, [{:synced, path} | ordered]}
          end

        _other, accumulated ->
          accumulated
      end)

    Enum.reverse(ordered)
  end

  defp normalize_path(path) when is_binary(path), do: Path.expand(path)

  defp normalize_path(path) when is_list(path),
    do: path |> IO.chardata_to_string() |> Path.expand()
end
