Code.require_file("support/durable_truth_helper.exs", __DIR__)

defmodule Loopex.FencingTest do
  @moduledoc """
  ## Concept

  Outcome 5: an effect committed with an unknown outcome is fenced, never
  blindly retried, and reconciled across a coordinator restart.

  The claim has three parts and each is asserted rather than inspected. Fenced
  means the mutation domain refuses further dispatch, publication, and any
  acknowledgement of the effect. Never retried means a counting collector shows
  exactly one dispatch for the transaction across the whole run, including across
  restarts. Reconciled means a solicited receipt — and only a solicited one —
  resolves the fence.

  ## Technical depth

  Restarts are induced kills, and one case crashes the coordinator from inside
  the dispatch window itself: the dispatch target kills the coordinator on
  receiving the dispatch, so the intent is durable, the dispatch left the
  process, and no outcome was ever recorded. That is the state recovery cannot
  distinguish from a crash before the dispatch, which is exactly why it must
  fence instead of retrying.

  The admission rules are also exercised field by field: mutating or dropping any
  single field of an otherwise admissible answer must reject it. A single happy
  path would leave every one of those comparisons untested.
  """

  use ExUnit.Case, async: true

  alias Loopex.Coordinator
  alias Loopex.Effect
  alias Loopex.Session
  alias LoopexTest.DurableTruth

  @seeds [2, 11, 29, 307, 8_191]
  @workload_steps 24

  setup do
    Process.flag(:trap_exit, true)
    {:ok, collector: DurableTruth.start_collector()}
  end

  test "commit_unknown is fenced and never dispatched a second time", %{collector: collector} do
    journal = DurableTruth.journal_path("commit-unknown")
    session_id = "session-commit-unknown"

    {:ok, pid} = DurableTruth.start(journal, session_id, collector)
    {:ok, tx} = Coordinator.dispatch(pid, DurableTruth.request("op-1", :workspace, %{n: 1}))

    assert length(DurableTruth.report(collector).dispatches) == 1

    :ok = Coordinator.commit_unknown(pid, tx)
    assert Session.fence(Coordinator.durable_state(pid), :workspace) == {:fenced, tx}

    # The fence refuses every observable consequence: another dispatch in the
    # domain, a publication in the domain, and any acknowledgement of the effect
    # itself -- even from an answer that would otherwise be admissible.
    assert {:error, {:fenced, ^tx}} =
             Coordinator.dispatch(pid, DurableTruth.request("op-2", :workspace, %{n: 2}))

    assert {:error, {:fenced, ^tx}} = Coordinator.commit_fact(pid, :workspace, "public claim")

    assert {:error, {:fenced, ^tx}} =
             Coordinator.complete(pid, DurableTruth.live_result(pid, tx, :committed, "done"))

    # The same refusal repeated: a caller that keeps asking never gets through.
    assert {:error, {:fenced, ^tx}} =
             Coordinator.dispatch(pid, DurableTruth.request("op-3", :workspace, %{n: 3}))

    # A restart does not lift the fence, and recovery does not redispatch.
    DurableTruth.kill(pid)
    {:ok, restarted} = DurableTruth.start(journal, session_id, collector)

    assert Session.unknown_txs(Coordinator.durable_state(restarted)) == [tx]

    assert {:error, {:fenced, ^tx}} =
             Coordinator.dispatch(restarted, DurableTruth.request("op-2", :workspace, %{n: 2}))

    # An unrelated domain is untouched: the fence is scoped to the mutation
    # domain, not to the session.
    assert {:ok, other} =
             Coordinator.dispatch(restarted, DurableTruth.request("op-4", :network, %{n: 4}))

    refute other == tx

    report = DurableTruth.report(collector)

    # The counted assertion: exactly one dispatch ever carried this transaction,
    # across both coordinator incarnations.
    assert Enum.count(report.dispatches, &(Map.fetch!(&1, :tx_id) == tx)) == 1
    assert length(report.dispatches) == 2
    assert report.publications == []
  end

  test "a stale completion is rejected after a coordinator restart", %{collector: collector} do
    journal = DurableTruth.journal_path("stale-completion")
    session_id = "session-stale-completion"

    {:ok, first} = DurableTruth.start(journal, session_id, collector)
    {:ok, tx} = Coordinator.dispatch(first, DurableTruth.request("op-1", :workspace, %{n: 1}))

    # An answer produced under the first incarnation, held while it dies.
    stale = DurableTruth.live_result(first, tx, :committed, "mutated the workspace")
    assert Map.fetch!(stale, :session_epoch) == Coordinator.durable_state(first).epoch

    DurableTruth.kill(first)
    {:ok, second} = DurableTruth.start(journal, session_id, collector)
    recovered = Coordinator.durable_state(second)

    # Recovery fenced the effect and took a new epoch, so the stale answer is
    # inadmissible twice over.
    assert Session.unknown_txs(recovered) == [tx]
    assert recovered.epoch == Map.fetch!(stale, :session_epoch) + 1
    assert {:error, {:fenced, ^tx}} = Coordinator.complete(second, stale)

    # The epoch rule rejects it on its own, independently of the fence, so the
    # refusal does not depend on which of the two mechanisms is consulted first.
    assert {:ok, intent} = Session.intent(recovered, tx)

    assert {:error, {:mismatch, :session_epoch}} =
             Effect.admit_live_result(intent, stale, recovered.epoch)

    # Re-stamping the current epoch does not launder it either: an unsolicited
    # answer about a fenced effect is not admissible evidence at all.
    refreshed = Map.put(stale, :session_epoch, recovered.epoch)
    assert {:error, {:fenced, ^tx}} = Coordinator.complete(second, refreshed)

    report = DurableTruth.report(collector)
    assert length(report.dispatches) == 1
    assert report.publications == []
    assert Session.facts(Coordinator.durable_state(second)) == []
  end

  test "an effect whose dispatch outlived the coordinator is fenced, not retried", %{
    collector: collector
  } do
    journal = DurableTruth.journal_path("dispatch-window")
    session_id = "session-dispatch-window"
    request = DurableTruth.request("op-1", :workspace, %{n: 1})

    # Concept: a dispatch target that kills the coordinator the moment it
    # receives the dispatch. The intent is durable, the dispatch left the
    # process, and no outcome was ever recorded -- the window the invariant is
    # about.
    test = self()

    hostile =
      spawn_link(fn ->
        receive do
          {:coordinator, coordinator} ->
            receive do
              {:loopex_dispatch, _payload} = message ->
                send(collector, message)
                Process.exit(coordinator, :kill)
                send(test, :dispatch_observed)
            end
        end
      end)

    {:ok, pid} = DurableTruth.start(journal, session_id, hostile)
    send(hostile, {:coordinator, pid})

    # The kill races the reply, and either order is the scenario under test: what
    # matters is that the intent was durable, the dispatch crossed the boundary,
    # and the coordinator then died without recording an outcome. Asserting on
    # which side of the reply the kill landed would test the scheduler.
    outcome =
      try do
        Coordinator.dispatch(pid, request)
      catch
        :exit, _reason -> :died_before_replying
      end

    assert outcome == :died_before_replying or match?({:ok, _tx}, outcome)
    assert_receive :dispatch_observed, 2_000
    assert_receive {:EXIT, ^pid, _reason}, 2_000

    {:ok, restarted} = DurableTruth.start(journal, session_id, collector)
    recovered = Coordinator.durable_state(restarted)

    # The intent is on disk, so recovery found it; it is fenced, not pending, and
    # not resolved.
    assert [tx] = Session.unknown_txs(recovered)
    assert Session.pending_txs(recovered) == []
    assert recovered.resolved == %{}

    # The identical request is refused rather than retried, which is the whole
    # point: the coordinator cannot know whether the executor acted.
    assert {:error, {:fenced, ^tx}} = Coordinator.dispatch(restarted, request)

    # The preallocated id is recoverable from the operation identity alone.
    assert {:ok, ^tx} = Session.tx_for_operation(recovered, "op-1", 1)

    # And the journaled digest still matches the journaled request, so the
    # binding is checkable rather than merely recorded.
    assert {:ok, intent} = Session.intent(recovered, tx)

    assert Effect.canonical_request_digest(Effect.request_of(intent)) ==
             Map.fetch!(intent, :canonical_request_digest)

    assert length(DurableTruth.report(collector).dispatches) == 1
  end

  test "only a solicited receipt for the current query resolves a fence", %{collector: collector} do
    journal = DurableTruth.journal_path("reconciliation")
    session_id = "session-reconciliation"

    {:ok, first} = DurableTruth.start(journal, session_id, collector)
    {:ok, tx} = Coordinator.dispatch(first, DurableTruth.request("op-1", :workspace, %{n: 1}))
    DurableTruth.kill(first)

    {:ok, pid} = DurableTruth.start(journal, session_id, collector)
    assert Session.unknown_txs(Coordinator.durable_state(pid)) == [tx]

    # Unsolicited: no query is open, so nothing can be admitted.
    unsolicited = DurableTruth.receipt(pid, tx, "no-such-query", :committed, "did it")
    assert {:error, :unsolicited} = Coordinator.reconcile(pid, unsolicited)

    # A query is opened, then superseded. The receipt answering the first query
    # is no longer solicited.
    assert {:ok, first_query, [^tx]} = Coordinator.reconciliation_query(pid)
    assert {:ok, second_query, [^tx]} = Coordinator.reconciliation_query(pid)
    refute first_query == second_query

    stale_answer = DurableTruth.receipt(pid, tx, first_query, :committed, "did it")

    assert {:error, {:mismatch, :reconciliation_query_id}} =
             Coordinator.reconcile(pid, stale_answer)

    assert Session.unknown_txs(Coordinator.durable_state(pid)) == [tx]
    assert DurableTruth.report(collector).publications == []

    # The solicited answer resolves it, publishes its fact, and lifts the fence.
    solicited = DurableTruth.receipt(pid, tx, second_query, :committed, "wrote the workspace")
    assert :ok = Coordinator.reconcile(pid, solicited)

    resolved = Coordinator.durable_state(pid)
    assert Session.unknown_txs(resolved) == []
    assert Session.status(resolved, tx) == {:resolved, :committed}
    assert Session.fence(resolved, :workspace) == :open
    assert Session.facts(resolved) == ["wrote the workspace"]

    # A second receipt cannot resolve it again, and the fence stays lifted across
    # a restart.
    assert {:error, {:not_fenced, ^tx, {:resolved, :committed}}} =
             Coordinator.reconcile(pid, solicited)

    DurableTruth.kill(pid)
    {:ok, final} = DurableTruth.start(journal, session_id, collector)
    assert Session.fence(Coordinator.durable_state(final), :workspace) == :open
    assert Session.facts(Coordinator.durable_state(final)) == ["wrote the workspace"]

    report = DurableTruth.report(collector)
    assert length(report.dispatches) == 1
    assert report.publications == ["wrote the workspace"]
  end

  test "mutating or dropping any admitted field rejects a live result", %{collector: collector} do
    journal = DurableTruth.journal_path("live-fields")
    session_id = "session-live-fields"

    {:ok, pid} = DurableTruth.start(journal, session_id, collector)
    {:ok, tx} = Coordinator.dispatch(pid, DurableTruth.request("op-1", :workspace, %{n: 1}))

    admissible = DurableTruth.live_result(pid, tx, :committed, "wrote it")
    state = Coordinator.durable_state(pid)
    assert {:ok, intent} = Session.intent(state, tx)
    assert :ok = Effect.admit_live_result(intent, admissible, state.epoch)

    for field <- DurableTruth.admitted_fields() ++ [:session_epoch] do
      mutated = Map.put(admissible, field, mutate(Map.fetch!(admissible, field)))

      assert {:error, {:mismatch, ^field}} =
               Effect.admit_live_result(intent, mutated, state.epoch),
             "a mutated #{field} was admitted"

      dropped = Map.delete(admissible, field)

      assert {:error, {:mismatch, ^field}} =
               Effect.admit_live_result(intent, dropped, state.epoch),
             "a missing #{field} was admitted"

      # The coordinator refuses the same answers. A mutated transaction id names
      # no transaction at all, which is a different and stricter refusal.
      expected =
        case field do
          :tx_id -> {:error, {:no_such_tx, Map.fetch!(mutated, :tx_id)}}
          _other -> {:error, {:mismatch, field}}
        end

      assert Coordinator.complete(pid, mutated) == expected
    end

    # Nothing was admitted, so the effect is still awaited and nothing was
    # published.
    assert Session.pending_txs(Coordinator.durable_state(pid)) == [tx]
    assert DurableTruth.report(collector).publications == []

    # The untouched answer is still admitted, so the refusals above were about
    # the mutations and not about the coordinator having given up.
    assert :ok = Coordinator.complete(pid, admissible)
    assert DurableTruth.report(collector).publications == ["wrote it"]
  end

  test "mutating or dropping any retained field rejects a reconciliation receipt", %{
    collector: collector
  } do
    journal = DurableTruth.journal_path("receipt-fields")
    session_id = "session-receipt-fields"

    {:ok, first} = DurableTruth.start(journal, session_id, collector)
    {:ok, tx} = Coordinator.dispatch(first, DurableTruth.request("op-1", :workspace, %{n: 1}))
    DurableTruth.kill(first)

    {:ok, pid} = DurableTruth.start(journal, session_id, collector)
    assert {:ok, query_id, [^tx]} = Coordinator.reconciliation_query(pid)

    admissible = DurableTruth.receipt(pid, tx, query_id, :committed, "wrote it")
    state = Coordinator.durable_state(pid)
    assert {:ok, intent} = Session.intent(state, tx)

    expected = %{
      reconciliation_query_id: query_id,
      session_epoch: state.epoch,
      executor_identity: DurableTruth.executor().identity
    }

    assert :ok = Effect.admit_receipt(intent, admissible, expected)

    fields =
      DurableTruth.admitted_fields() ++
        [:reconciliation_query_id, :session_epoch, :session_epoch_at_dispatch]

    for field <- fields do
      mutated = Map.put(admissible, field, mutate(Map.fetch!(admissible, field)))

      assert {:error, {:mismatch, ^field}} = Effect.admit_receipt(intent, mutated, expected),
             "a mutated #{field} was admitted"

      dropped = Map.delete(admissible, field)

      assert {:error, {:mismatch, ^field}} = Effect.admit_receipt(intent, dropped, expected),
             "a missing #{field} was admitted"
    end

    # The fence never lifted while every one of those was refused.
    assert Session.unknown_txs(Coordinator.durable_state(pid)) == [tx]
    assert DurableTruth.report(collector).publications == []
  end

  test "a generated workload never dispatches into a fenced domain" do
    reached =
      Enum.reduce(@seeds, %{fenced: 0, restarts: 0, reconciled: 0}, fn seed, totals ->
        Map.merge(totals, workload(seed), fn _key, running, added -> running + added end)
      end)

    # The invariant is only worth asserting if the workload actually reached the
    # states it is about. A run that never fenced a domain, never restarted, and
    # never reconciled would satisfy every assertion above vacuously.
    assert reached.fenced > 0, "no dispatch was ever refused by a fence"
    assert reached.restarts > 0, "no coordinator was ever restarted"
    assert reached.reconciled > 0, "no fence was ever resolved by reconciliation"
  end

  # Concept: drive a coordinator through a reproducible sequence of dispatches,
  # unknown outcomes, resolutions, and kills, checking the fence invariant at
  # every step against the collector's own count.
  # Technical depth: the oracle is read from durable state before each dispatch,
  # so what should happen is computed independently of what the call returns.
  # Returns how many times the run reached each state worth counting.
  defp workload(seed) do
    session_id = "session-workload-#{seed}"
    journal = DurableTruth.journal_path("workload-#{seed}")
    collector = DurableTruth.start_collector()
    {:ok, pid} = DurableTruth.start(journal, session_id, collector)

    initial = %{
      pid: pid,
      collector: collector,
      journal: journal,
      session_id: session_id,
      seed: seed,
      step: 0,
      dispatched: [],
      fenced: 0,
      restarts: 0,
      reconciled: 0
    }

    {_rng, run} =
      Enum.reduce(1..@workload_steps, {DurableTruth.seed(seed), initial}, fn number, {rng, run} ->
        {action, rng} =
          DurableTruth.pick(rng, [:dispatch, :dispatch, :unknown, :resolve, :restart])

        {domain, rng} = DurableTruth.pick(rng, [:workspace, :network])
        {rng, step(action, %{run | step: number}, domain)}
      end)

    report = DurableTruth.report(collector)

    # Every dispatch the coordinator acknowledged crossed the boundary exactly
    # once, in order, and nothing crossed it that was not acknowledged.
    assert Enum.map(report.dispatches, &Map.fetch!(&1, :tx_id)) == Enum.reverse(run.dispatched),
           "seed #{seed}: dispatches do not match the acknowledged transactions"

    assert length(Enum.uniq(run.dispatched)) == length(run.dispatched),
           "seed #{seed}: a transaction was dispatched more than once"

    Map.take(run, [:fenced, :restarts, :reconciled])
  end

  defp step(:dispatch, run, domain) do
    crossed = crossed(run)
    request = DurableTruth.request("op-#{run.seed}-#{run.step}", domain, %{step: run.step})

    case Session.fence(Coordinator.durable_state(run.pid), domain) do
      {:fenced, tx} ->
        assert Coordinator.dispatch(run.pid, request) == {:error, {:fenced, tx}},
               "#{at(run)}: a fenced domain accepted a dispatch"

        assert crossed(run) == crossed,
               "#{at(run)}: a refused dispatch still crossed the boundary"

        %{run | fenced: run.fenced + 1}

      :open ->
        assert {:ok, tx} = Coordinator.dispatch(run.pid, request)

        assert crossed(run) == crossed + 1,
               "#{at(run)}: an accepted dispatch did not cross the boundary exactly once"

        %{run | dispatched: [tx | run.dispatched]}
    end
  end

  defp step(:unknown, run, _domain) do
    case Session.pending_txs(Coordinator.durable_state(run.pid)) do
      [] ->
        run

      [tx | _rest] ->
        assert :ok = Coordinator.commit_unknown(run.pid, tx)
        state = Coordinator.durable_state(run.pid)
        {:ok, intent} = Session.intent(state, tx)

        # The domain is fenced and this transaction is one of the effects holding
        # it. Which transaction `fence/2` names is deterministic but not
        # necessarily this one: an earlier unknown effect in the same domain is
        # named first, so asserting on identity here would test the tie-break
        # rather than the fence.
        assert match?({:fenced, _tx}, Session.fence(state, Map.fetch!(intent, :domain))),
               "#{at(run)}: an unknown outcome did not fence its domain"

        assert tx in Session.unknown_txs(state),
               "#{at(run)}: an unknown outcome was not recorded as unknown"

        run
    end
  end

  defp step(:resolve, run, _domain) do
    state = Coordinator.durable_state(run.pid)

    cond do
      Session.unknown_txs(state) != [] ->
        {:ok, query_id, [tx | _rest]} = Coordinator.reconciliation_query(run.pid)

        receipt =
          DurableTruth.receipt(run.pid, tx, query_id, :committed, "reconciled #{run.step}")

        assert :ok = Coordinator.reconcile(run.pid, receipt)

        assert Session.status(Coordinator.durable_state(run.pid), tx) == {:resolved, :committed},
               "#{at(run)}: a solicited receipt did not resolve the fence"

        %{run | reconciled: run.reconciled + 1}

      Session.pending_txs(state) != [] ->
        [tx | _rest] = Session.pending_txs(state)

        assert :ok =
                 Coordinator.complete(
                   run.pid,
                   DurableTruth.live_result(run.pid, tx, :failed, nil)
                 )

        run

      true ->
        run
    end
  end

  defp step(:restart, run, _domain) do
    before = Coordinator.durable_state(run.pid)
    crossed = crossed(run)

    DurableTruth.kill(run.pid)
    {:ok, restarted} = DurableTruth.start(run.journal, run.session_id, run.collector)
    recovered = Coordinator.durable_state(restarted)

    assert Session.pending_txs(recovered) == [], "#{at(run)}: recovery left an effect pending"

    assert Enum.sort(Session.unknown_txs(recovered)) ==
             Enum.sort(Session.unknown_txs(before) ++ Session.pending_txs(before)),
           "#{at(run)}: recovery did not fence exactly the unresolved effects"

    assert crossed(run) == crossed, "#{at(run)}: recovery redispatched an effect"

    %{run | pid: restarted, restarts: run.restarts + 1}
  end

  defp crossed(run), do: length(DurableTruth.report(run.collector).dispatches)

  defp at(run), do: "seed #{run.seed} step #{run.step}"

  defp mutate(value) when is_binary(value), do: value <> "-mutated"
  defp mutate(value) when is_integer(value), do: value + 1
  defp mutate(value), do: {:mutated, value}
end
