Code.require_file("support/durable_truth_helper.exs", __DIR__)

defmodule Loopex.JournalReplayTest do
  @moduledoc """
  ## Concept

  Outcome 4: a session journal survives a restart, and replay reconstructs the
  same durable state.

  A clean shutdown is deliberately never used. Every restart here is an induced
  kill, and the store-level cases truncate the journal at every byte to stand in
  for a process that died partway through a write.

  ## Technical depth

  Three kinds of evidence, because the outcome's evidence class requires all
  three. Properties over generated histories check the reducer against an
  independent model and against the fold law replay depends on. Fault injection
  kills the owning process after each durable transition and truncates the
  journal at every byte offset. The negative demonstration is recorded with the
  milestone's evidence rather than here.
  """

  use ExUnit.Case, async: true

  alias Loopex.Coordinator
  alias Loopex.Journal
  alias Loopex.Session
  alias LoopexTest.DurableTruth

  # Technical depth: fixed seeds, so a failure is reproducible on both locked
  # toolchains and a bisect sees the same history the failing run saw.
  @seeds [1, 7, 13, 101, 4_242, 65_537]
  @history_length 40

  setup do
    # Concept: a killed coordinator is linked to this process, so exits must be
    # trapped or the test dies with it.
    Process.flag(:trap_exit, true)
    {:ok, collector: DurableTruth.start_collector()}
  end

  test "replay after an induced restart reconstructs the same durable state", %{
    collector: collector
  } do
    journal = DurableTruth.journal_path("induced-restart")
    session_id = "session-induced-restart"

    {:ok, first} = DurableTruth.start(journal, session_id, collector)

    :ok = Coordinator.commit_fact(first, :workspace, "workspace opened")
    {:ok, tx} = Coordinator.dispatch(first, DurableTruth.request("op-1", :workspace, %{n: 1}))
    :ok = Coordinator.complete(first, DurableTruth.live_result(first, tx, :committed, "wrote a"))
    :ok = Coordinator.commit_fact(first, :workspace, "workspace closed")

    before = Coordinator.durable_state(first)
    assert Session.facts(before) == ["workspace opened", "wrote a", "workspace closed"]

    DurableTruth.kill(first)

    {:ok, second} = DurableTruth.start(journal, session_id, collector)
    recovered = Coordinator.durable_state(second)

    # The durable content is identical across the restart.
    assert Session.facts(recovered) == Session.facts(before)
    assert recovered.resolved == before.resolved
    assert recovered.pending == before.pending
    assert recovered.unknown == before.unknown
    assert recovered.operations == before.operations

    # Only the recovery epoch advances, and it advances by exactly one.
    assert recovered.epoch == before.epoch + 1

    # An independent replay of the bytes on disk agrees with the process's own
    # state, so the state is a function of the journal and not of the process.
    assert {:ok, records, :complete} = Journal.read(journal)
    assert {:ok, replayed} = Session.replay(session_id, records)
    assert replayed == recovered

    # Recovery neither redispatched nor republished anything.
    report = DurableTruth.report(collector)
    assert length(report.dispatches) == 1
    assert report.publications == ["workspace opened", "wrote a", "workspace closed"]
  end

  test "a generated history replays to the state an independent model predicts" do
    kinds =
      Enum.reduce(@seeds, MapSet.new(), fn seed, seen ->
        session_id = "session-model-#{seed}"
        {records, model} = DurableTruth.history(seed, @history_length, session_id)

        assert {:ok, state} = Session.replay(session_id, records),
               "seed #{seed}: a legal history was refused"

        assert state.seq == model.seq, "seed #{seed}: sequence"
        assert state.epoch == model.epoch, "seed #{seed}: epoch"
        assert length(Session.facts(state)) == model.facts, "seed #{seed}: fact count"
        assert Session.pending_txs(state) == Enum.sort(model.pending), "seed #{seed}: pending"
        assert Session.unknown_txs(state) == Enum.sort(model.unknown), "seed #{seed}: unknown"
        assert map_size(state.resolved) == model.resolved, "seed #{seed}: resolved"

        MapSet.union(seen, MapSet.new(records, &Map.fetch!(&1, :kind)))
      end)

    # The generated histories really do cover every durable transition, so the
    # agreement above is about all five kinds and not only the ones that happened
    # to be generated.
    assert kinds ==
             MapSet.new([
               :session_opened,
               :fact_committed,
               :effect_intent,
               :effect_unknown,
               :effect_resolved
             ])
  end

  test "replay is deterministic and equals folding a suffix onto any prefix" do
    for seed <- @seeds do
      session_id = "session-fold-#{seed}"
      {records, _model} = DurableTruth.history(seed, @history_length, session_id)

      assert {:ok, whole} = Session.replay(session_id, records)
      assert {:ok, again} = Session.replay(session_id, records)
      assert again == whole, "seed #{seed}: replay is not deterministic"

      # The fold law is what lets a restart resume from a prefix: replaying a
      # prefix and then applying the rest must reach the same state as replaying
      # everything. Checked at every split, not a sampled one.
      for split <- 0..length(records) do
        {prefix, suffix} = Enum.split(records, split)

        assert {:ok, partial} = Session.replay(session_id, prefix),
               "seed #{seed}: prefix of #{split} records was refused"

        folded =
          Enum.reduce(suffix, partial, fn record, state ->
            assert {:ok, next} = Session.apply_record(state, record)
            next
          end)

        assert folded == whole, "seed #{seed}: split at #{split} diverged"
      end
    end
  end

  test "a journal truncated at any byte replays to an intact prefix" do
    session_id = "session-truncation"
    {records, _model} = DurableTruth.history(31, 24, session_id)
    journal = DurableTruth.journal_path("truncation")

    Enum.each(records, fn record -> assert :ok = Journal.append(journal, record) end)

    assert {:ok, ^records, :complete} = Journal.read(journal)

    bytes = File.read!(journal)

    # Technical depth: the frame layout is recomputed here from the same
    # deterministic encoding the journal writes, so the expected record count at
    # a given truncation is derived independently of what the reader reports. A
    # test that trusted the reader's own count could not catch a reader that
    # skipped a torn frame and kept going.
    boundaries =
      Enum.scan(records, 0, fn record, offset ->
        offset + 8 + byte_size(:erlang.term_to_binary(record, [:deterministic]))
      end)

    partial = DurableTruth.journal_path("truncation-partial")
    File.mkdir_p!(Path.dirname(partial))

    # Every byte offset stands for a process killed at that point in a write.
    for cut <- 0..byte_size(bytes) do
      File.write!(partial, binary_part(bytes, 0, cut))
      intact = Enum.count(boundaries, &(&1 <= cut))

      assert {:ok, read, tail} = Journal.read(partial),
             "truncated at #{cut} bytes: the journal could not be read"

      assert read == Enum.take(records, intact),
             "truncated at #{cut} bytes: expected the first #{intact} records"

      assert {:ok, _state} = Session.replay(session_id, read),
             "truncated at #{cut} bytes: the surviving prefix does not replay"

      # A cut on a frame boundary is a complete journal; a cut inside a frame is
      # reported torn, never silently skipped past.
      case cut == 0 or cut in boundaries do
        true -> assert tail == :complete, "truncated at #{cut} bytes: a whole journal read torn"
        false -> assert match?({:torn, _offset}, tail), "truncated at #{cut} bytes: tear missed"
      end
    end
  end

  test "a coordinator killed after each durable transition recovers the acknowledged state" do
    session_id = "session-per-transition"
    collector = DurableTruth.start_collector()

    # Concept: one workload that produces every durable transition kind, driven
    # one acknowledged step at a time so the kill can be placed after each.
    steps = [
      {:fact, "first fact"},
      {:dispatch, "op-1", :workspace},
      {:complete, "op-1"},
      {:dispatch, "op-2", :network},
      {:unknown, "op-2"},
      {:reconcile, "op-2"},
      {:fact, "last fact"}
    ]

    kinds =
      Enum.reduce(0..length(steps), MapSet.new(), fn cut, seen ->
        run = DurableTruth.journal_path("per-transition-cut-#{cut}")
        {:ok, pid} = DurableTruth.start(run, session_id, collector)

        steps
        |> Enum.take(cut)
        |> Enum.reduce(%{}, fn step, txs -> perform(pid, step, txs) end)

        expected = Coordinator.durable_state(pid)
        DurableTruth.kill(pid)

        {:ok, restarted} = DurableTruth.start(run, session_id, collector)
        recovered = Coordinator.durable_state(restarted)

        assert Session.facts(recovered) == Session.facts(expected),
               "cut #{cut}: facts did not survive the kill"

        assert recovered.resolved == expected.resolved,
               "cut #{cut}: resolutions did not survive the kill"

        assert recovered.operations == expected.operations,
               "cut #{cut}: operation identities did not survive the kill"

        assert recovered.epoch == expected.epoch + 1, "cut #{cut}: epoch did not advance"

        # Anything pending when the process died is fenced, never resumed.
        assert Session.pending_txs(recovered) == [],
               "cut #{cut}: an unresolved effect was left pending after recovery"

        assert Enum.sort(Session.unknown_txs(recovered)) ==
                 Enum.sort(Session.unknown_txs(expected) ++ Session.pending_txs(expected)),
               "cut #{cut}: recovery did not fence exactly the unresolved effects"

        assert {:ok, records, _tail} = Journal.read(run)
        MapSet.union(seen, MapSet.new(records, &Map.fetch!(&1, :kind)))
      end)

    # The workload really did exercise every durable transition, so "after each
    # transition" is a claim about all five and not about the ones that happened
    # to occur.
    assert kinds ==
             MapSet.new([
               :session_opened,
               :fact_committed,
               :effect_intent,
               :effect_unknown,
               :effect_resolved
             ])
  end

  test "a durable record refuses anything that is not plain boundary data" do
    journal = DurableTruth.journal_path("plain-data")

    for value <- [self(), make_ref(), fn -> :ok end, %Loopex.Session{}] do
      assert {:error, {:invalid_record, :not_plain_data}} =
               Journal.append(journal, %{kind: :fact_committed, seq: 1, fact: value})
    end

    assert {:error, {:invalid_record, :missing_kind}} = Journal.append(journal, %{seq: 1})

    # Nothing was written, so a refused record cannot be replayed later.
    assert {:ok, [], :complete} = Journal.read(journal)
  end

  test "a record out of sequence is refused rather than applied" do
    session_id = "session-sequence"
    state = Session.initial(session_id)
    opened = %{kind: :session_opened, seq: 1, session_id: session_id, epoch: 1}

    assert {:ok, state} = Session.apply_record(state, opened)

    # The same record again, a gap, and a record with no sequence at all.
    assert {:error, {:out_of_sequence, _}} = Session.apply_record(state, opened)

    assert {:error, {:out_of_sequence, _}} =
             Session.apply_record(state, %{kind: :fact_committed, seq: 9, fact: "gap"})

    assert {:error, {:out_of_sequence, _}} =
             Session.apply_record(state, %{kind: :fact_committed, fact: "no sequence"})
  end

  defp perform(pid, {:fact, fact}, txs) do
    :ok = Coordinator.commit_fact(pid, :workspace, fact)
    txs
  end

  defp perform(pid, {:dispatch, operation, domain}, txs) do
    {:ok, tx} =
      Coordinator.dispatch(pid, DurableTruth.request(operation, domain, %{op: operation}))

    Map.put(txs, operation, tx)
  end

  defp perform(pid, {:complete, operation}, txs) do
    tx = Map.fetch!(txs, operation)

    :ok =
      Coordinator.complete(pid, DurableTruth.live_result(pid, tx, :committed, "did #{operation}"))

    txs
  end

  defp perform(pid, {:unknown, operation}, txs) do
    :ok = Coordinator.commit_unknown(pid, Map.fetch!(txs, operation))
    txs
  end

  defp perform(pid, {:reconcile, operation}, txs) do
    tx = Map.fetch!(txs, operation)
    {:ok, query_id, [^tx]} = Coordinator.reconciliation_query(pid)
    receipt = DurableTruth.receipt(pid, tx, query_id, :committed, "reconciled #{operation}")
    :ok = Coordinator.reconcile(pid, receipt)
    txs
  end
end
