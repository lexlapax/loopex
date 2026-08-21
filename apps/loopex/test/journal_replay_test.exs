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

  # Concept: a generated failure has to be reproducible to be actionable.
  #
  # Technical depth: fixed seeds, so a failure is reproducible on both locked
  # toolchains and a bisect sees the same history the failing run saw.
  @seeds [1, 7, 13, 101, 4_242, 65_537]
  @history_length 40

  # Concept: a test that mutates a journal owns it, like every other writer.
  #
  # Technical depth: these cases used to append to an unclaimed journal, which is
  # the path that no longer exists. Claiming here is not ceremony -- it is the
  # same triple identity the Coordinator presents, taken from the test process, so
  # the case exercises the real rule rather than a relaxed one for tests.
  #
  # Deliberately no `on_exit` release: `on_exit` runs in a different process, and
  # a release from a process that is not the owner is refused -- correctly. Each
  # case uses a unique journal, so its sentinel is unique too.
  defp owned(journal) do
    {:ok, token} = Journal.claim_session(journal)
    token
  end

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

        # Every field of the struct is compared, and the list of fields is derived
        # from the struct rather than written out. Naming aspects by hand is how
        # this oracle failed three times: counts instead of values, then a field
        # list containing names the record does not have, then a comparison that
        # never looked at session_id at all, so a reducer admitting a foreign
        # session's records passed every seed. A field added later now fails loudly
        # here instead of going silently unchecked.
        expected = %{
          session_id: session_id,
          seq: model.seq,
          epoch: model.epoch,
          # The struct keeps facts newest-first; Session.facts/1 reverses on read.
          facts: Enum.reverse(model.facts),
          resolved: model.resolved,
          operations: model.operations,
          pending: Map.new(model.pending, &{&1, Map.fetch!(model.intents, &1)}),
          unknown: Map.new(model.unknown, &{&1, Map.fetch!(model.intents, &1)})
        }

        actual = Map.from_struct(state)

        assert Map.keys(actual) |> Enum.sort() == Map.keys(expected) |> Enum.sort(),
               "seed #{seed}: the session struct gained or lost a field the model does not " <>
                 "predict; extend the model rather than leaving it uncompared"

        assert actual == expected, "seed #{seed}: replayed state differs from the model"

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

  test "a fact acknowledged after torn-tail recovery survives the next restart" do
    # This is the case the truncation test above does not reach. That test proves a
    # torn journal reads back an intact prefix; it never continues past recovery.
    # Continuing is where durability was actually broken: append/2 writes at the
    # end of the file and read/1 stops at the first bad frame, so a tear left in
    # place made every later record unreachable. Recovery replayed the prefix, the
    # coordinator acknowledged and published a new fact, and that fact vanished on
    # the next restart -- durable truth that was not durable.
    collector = DurableTruth.start_collector()
    journal = DurableTruth.journal_path("torn-continuation")

    {:ok, first} = DurableTruth.start(journal, "session-torn", collector)
    assert :ok = Coordinator.commit_fact(first, :workspace, "before the tear")
    {:ok, before_records, :complete} = Journal.read(journal)
    DurableTruth.kill(first)

    # A partial frame, exactly as a process killed mid-append would leave.
    File.open!(journal, [:append, :binary], fn io -> IO.binwrite(io, <<255, 255, 255>>) end)

    intact_size =
      Enum.reduce(before_records, 0, fn record, size ->
        size + 8 + byte_size(:erlang.term_to_binary(record, [:deterministic]))
      end)

    assert {:ok, ^before_records, {:torn, ^intact_size}} = Journal.read(journal)

    {:ok, second} = DurableTruth.start(journal, "session-torn", collector)

    # Recovery discarded the tear and nothing else. This compares decoded records
    # rather than bytes; the byte-level guarantee is asserted by the repair itself,
    # which refuses when the surviving prefix would change.
    assert {:ok, recovered_records, :complete} = Journal.read(journal)
    assert Enum.take(recovered_records, length(before_records)) == before_records

    assert :ok = Coordinator.commit_fact(second, :workspace, "after the tear")
    live = Session.facts(Coordinator.durable_state(second))
    assert "after the tear" in live
    DurableTruth.kill(second)

    {:ok, third} = DurableTruth.start(journal, "session-torn", collector)
    survived = Session.facts(Coordinator.durable_state(third))

    assert "before the tear" in survived

    assert "after the tear" in survived,
           "a fact acknowledged and published after recovery was lost across restart"

    assert Session.facts(Coordinator.durable_state(third)) == live
  end

  test "repair never deletes an intact record beyond the damage" do
    # The first version of this repair assumed every tear was trailing. Interior
    # damage leaves intact records AFTER the bad point, and truncating from there
    # destroyed acknowledged durable truth -- a worse defect than the one the
    # repair was written to fix. Two shapes reach that state and both must refuse.
    build = fn name, count ->
      journal = DurableTruth.journal_path(name)
      token = owned(journal)

      for seq <- 1..count do
        assert :ok =
                 Journal.append(
                   journal,
                   %{kind: :fact_committed, seq: seq, fact: "f#{seq}"},
                   token
                 )
      end

      {journal, token}
    end

    # A complete frame whose payload changed under it. That is corruption, never a
    # torn append, because a killed writer cannot leave a whole frame with bad bytes.
    {interior, interior_token} = build.("interior-corruption", 3)
    size = File.stat!(interior).size
    bytes = File.read!(interior)
    at = 60

    File.write!(
      interior,
      binary_part(bytes, 0, at) <>
        <<:binary.at(bytes, at) + 1>> <>
        binary_part(bytes, at + 1, byte_size(bytes) - at - 1)
    )

    assert {:ok, [_first], {:corrupt, offset}} = Journal.read(interior)

    assert {:error, {:corrupt_not_torn, ^interior, ^offset}} =
             Journal.discard_torn_tail(interior, offset, interior_token)

    assert File.stat!(interior).size == size, "corruption must not cost a single byte"

    # A corrupted length prefix claims more bytes than remain, so the tail reads as
    # a strict prefix while whole records sit beyond it. The short shape alone is
    # not proof of a torn append.
    {inflated, inflated_token} = build.("inflated-length", 3)
    size = File.stat!(inflated).size
    bytes = File.read!(inflated)
    <<first_size::unsigned-big-32, _crc::unsigned-big-32, _rest::binary>> = bytes
    second = 8 + first_size

    File.write!(
      inflated,
      binary_part(bytes, 0, second) <>
        <<0xFFFFFF00::unsigned-big-32>> <>
        binary_part(bytes, second + 4, byte_size(bytes) - second - 4)
    )

    assert {:ok, [_kept], {:torn, torn_at}} = Journal.read(inflated)

    assert {:error, {:intact_record_beyond_tear, ^inflated, ^torn_at}} =
             Journal.discard_torn_tail(inflated, torn_at, inflated_token)

    assert File.stat!(inflated).size == size, "an intact record beyond the tear must survive"
  end

  test "one owner holds a journal for its whole life and a second cannot start" do
    # This is the property that replaced "append checks for a sentinel". A check is
    # not exclusion: a repair could begin between the check and the write, and the
    # append it destroyed had already been acknowledged. Holding the claim for the
    # owner's lifetime makes a second owner impossible instead.
    Process.flag(:trap_exit, true)
    collector = DurableTruth.start_collector()
    journal = DurableTruth.journal_path("one-owner")

    {:ok, first} = DurableTruth.start(journal, "session-one-owner", collector)
    assert {:ok, lock} = Journal.session_lock_path(journal)
    assert File.exists?(lock), "the owner must hold its claim while it runs"

    assert {:error, {:journal_claimed_by_another_owner, _held}} =
             DurableTruth.start(journal, "session-one-owner", collector)

    # Every alias of one journal contends for the same claim.
    alias_path = journal <> ".alias"
    File.ln_s!(journal, alias_path)
    on_exit(fn -> File.rm(alias_path) end)
    assert {:ok, ^lock} = Journal.session_lock_path(alias_path)

    assert {:error, {:journal_claimed_by_another_owner, _also}} =
             DurableTruth.start(alias_path, "session-one-owner", collector)

    # A clean stop releases it, so the next owner starts without human help.
    GenServer.stop(first)
    refute File.exists?(lock), "a clean stop must release the claim"
    {:ok, second} = DurableTruth.start(journal, "session-one-owner", collector)

    # A killed owner cannot release it, and an Erlang pid on this node that is not
    # alive is definitively gone -- so takeover is exact rather than a guess.
    DurableTruth.kill(second)
    assert File.exists?(lock), "a killed owner leaves its claim behind"
    {:ok, third} = DurableTruth.start(journal, "session-one-owner", collector)
    assert :ok = Coordinator.commit_fact(third, :workspace, "after takeover")
    GenServer.stop(third)
  end

  test "a claim is a capability, not a fact about a path" do
    # This case owns its claim lifecycle explicitly; it must not be pre-claimed.
    journal = DurableTruth.journal_path("claim-capability")
    assert {:ok, claim} = Journal.claim_session(journal)
    assert {:ok, lock} = Journal.session_lock_path(journal)
    on_exit(fn -> File.rm(lock) end)

    # The sentinel must not carry the token. It is deliberately readable so an
    # operator can see who holds a journal, and writing the bearer value into it
    # published the capability to every process running as the same user -- a
    # review read it, released the live owner, and claimed the journal.
    contents = File.read!(lock)
    refute String.contains?(contents, claim), "the sentinel must not publish the token"
    assert String.contains?(contents, "token_digest="), "it must carry a digest instead"
    assert String.contains?(contents, "node="), "operator fields must survive"
    assert String.contains?(contents, "os_pid=")

    # Presenting the digest is not presenting the token.
    [_all, digest] = Regex.run(~r/token_digest=([0-9a-f]+)/, contents)
    record = %{kind: :fact_committed, seq: 1, fact: "x"}
    assert {:error, {:not_the_session_owner, ^journal}} = Journal.append(journal, record, digest)
    assert {:error, {:not_the_claim_holder, ^lock}} = Journal.release_session(journal, digest)

    # A second claim is refused while the first holder is alive.
    assert {:error, {:repair_already_held, ^lock, _who}} = Journal.claim_session(journal)

    # Releasing and writing require having claimed.
    assert {:error, {:not_the_claim_holder, ^lock}} = Journal.release_session(journal, "wrong")
    assert File.exists?(lock), "a refused release must not remove the claim"
    assert {:error, {:not_the_session_owner, ^journal}} = Journal.append(journal, record, nil)
    assert {:error, {:not_the_session_owner, ^journal}} = Journal.append(journal, record, "wrong")
    assert :ok = Journal.append(journal, record, claim)

    # The DESTRUCTIVE path is inside the capability too. It took no token at all,
    # so a foreign process truncated a journal whose claim someone else held --
    # the one operation that deletes durable bytes was outside the mechanism built
    # to protect them.
    File.open!(journal, [:append, :binary], fn io -> IO.binwrite(io, <<0, 0, 0, 90, 1>>) end)
    assert {:ok, kept, {:torn, offset}} = Journal.read(journal)
    size = File.stat!(journal).size

    # Presenting nothing, and presenting the wrong token, are both refused.
    assert {:error, {:not_the_session_owner, ^journal}} =
             Journal.discard_torn_tail(journal, offset, nil)

    assert {:error, {:not_the_session_owner, ^journal}} =
             Journal.discard_torn_tail(journal, offset, "wrong")

    assert File.stat!(journal).size == size, "a refused repair must not alter the journal"
    assert :ok = Journal.discard_torn_tail(journal, offset, claim)
    assert {:ok, ^kept, :complete} = Journal.read(journal)

    # An unreadable or foreign claim is refused, not waved through.
    File.write!(lock, "garbage\n")

    assert {:error, {:claim_unreadable, ^lock, :malformed}} =
             Journal.append(journal, record, claim)

    foreign = "node=elsewhere os_pid=1 erl_pid=#PID<0.9.0> token_digest=abc at=0\n"
    File.write!(lock, foreign)
    assert {:error, {:not_the_session_owner, ^journal}} = Journal.append(journal, record, claim)

    # An owner in another VM cannot be verified from here, so it is never evicted.
    unverifiable = "node=#{node()} os_pid=999999 erl_pid=#PID<0.99999.0> token_digest=abc at=0\n"
    File.write!(lock, unverifiable)
    assert {:error, {:repair_already_held, ^lock, _}} = Journal.claim_session(journal)
    assert File.read!(lock) == unverifiable, "an unverifiable claim must survive untouched"

    # A takeover in progress excludes a second contender.
    dead = "node=#{node()} os_pid=#{System.pid()} erl_pid=#PID<0.99999.0> token_digest=abc at=0\n"
    File.write!(lock, dead)
    File.write!(lock <> ".takeover", "held\n")
    assert {:error, {:repair_already_held, ^lock, _}} = Journal.claim_session(journal)
    File.rm!(lock <> ".takeover")

    # With no contender, a provably dead owner in this VM is taken over.
    assert {:ok, taken} = Journal.claim_session(journal)
    refute taken == claim
    assert :ok = Journal.release_session(journal, taken)
    refute File.exists?(lock)
  end

  test "a record appended after a tear survives a later repair" do
    # The reviewer's reproduction in its deterministic form: a repairer verifies a
    # tear, another writer appends a complete record, and the repair must not
    # delete it. The repair's own record-count check cannot notice, because the
    # surviving prefix count is unchanged either way.
    journal = DurableTruth.journal_path("append-after-tear")
    token = owned(journal)
    assert :ok = Journal.append(journal, %{kind: :fact_committed, seq: 1, fact: "a"}, token)
    File.open!(journal, [:append, :binary], fn io -> IO.binwrite(io, <<0, 0, 0, 90, 1>>) end)
    assert {:ok, _kept, {:torn, offset}} = Journal.read(journal)

    # A second writer lands a complete, synced record beyond the tear.
    assert :ok = Journal.append(journal, %{kind: :fact_committed, seq: 2, fact: "b"}, token)
    grown = File.stat!(journal).size

    assert {:error, {:intact_record_beyond_tear, ^journal, ^offset}} =
             Journal.discard_torn_tail(journal, offset, token)

    assert File.stat!(journal).size == grown,
           "a record acknowledged after the tear must survive the repair"
  end

  test "a coordinator refuses to start on a corrupt journal rather than repairing it" do
    collector = DurableTruth.start_collector()
    journal = DurableTruth.journal_path("corrupt-refusal")

    {:ok, first} = DurableTruth.start(journal, "session-corrupt", collector)
    assert :ok = Coordinator.commit_fact(first, :workspace, "one")
    assert :ok = Coordinator.commit_fact(first, :workspace, "two")
    DurableTruth.kill(first)

    bytes = File.read!(journal)
    size = byte_size(bytes)
    at = div(size, 2)

    File.write!(
      journal,
      binary_part(bytes, 0, at) <>
        <<:binary.at(bytes, at) + 1>> <>
        binary_part(bytes, at + 1, size - at - 1)
    )

    assert {:ok, _records, {:corrupt, _offset}} = Journal.read(journal)

    Process.flag(:trap_exit, true)

    assert {:error, {:recovery_failed, {:journal_corrupt, ^journal, _}}} =
             DurableTruth.start(journal, "session-corrupt", collector)

    assert File.stat!(journal).size == size, "a refused start must not alter the journal"

    # A refused start must not strand the claim it took. `init/1` claims before it
    # can know whether recovery will succeed, and gen_server does NOT call
    # terminate/2 when init/1 returns {:stop, _} -- so every failure after the
    # claim left the sentinel behind. Within one VM the next start took it over,
    # which is why nothing caught this; after a VM restart the recorded os_pid is
    # no longer this process, the owner cannot be proved dead, and the session was
    # unstartable until a human deleted a file in a temp directory. Repairing the
    # journal is the operator's expected next move, and it has to be enough.
    assert {:ok, lock} = Journal.session_lock_path(journal)
    refute File.exists?(lock), "a refused start must release the claim it took"
  end

  test "a start that raises on a missing option must not leave the journal claimed" do
    collector = DurableTruth.start_collector()
    journal = DurableTruth.journal_path("raise-releases")

    # A real journal has to exist first: the sentinel is keyed by device and
    # inode, so there is no lock path to assert about until there is a file.
    {:ok, first} = DurableTruth.start(journal, "session-raise", collector)
    assert :ok = Coordinator.commit_fact(first, :workspace, "one")

    # Stopped rather than killed: a clean stop runs terminate/2 and releases, so
    # the lock this test asserts about can only have come from the failed start.
    :ok = GenServer.stop(first)

    assert {:ok, lock} = Journal.session_lock_path(journal)
    refute File.exists?(lock), "a clean stop must release before this starts"

    # gen_server does not call terminate/2 when init/1 RAISES, exactly as it does
    # not when init/1 returns {:stop, _}. The first version of the release fix
    # covered only the second, and two required options were still fetched after
    # the claim -- so a caller that omitted one stranded the sentinel through a
    # path the {:stop, _} test could not reach.
    #
    # Every required option is now read before the claim is taken, which is why
    # this raises without a lock file existing rather than raising after one was
    # created. The assertion is on the lock, not on the raise: raising is the
    # correct response to a missing option and was never in question.
    Process.flag(:trap_exit, true)

    # gen_server catches the raise and reports it, rather than letting it
    # propagate out of start_link.
    assert {:error, {%KeyError{key: :executor}, _stacktrace}} =
             GenServer.start_link(Coordinator,
               journal: journal,
               session_id: "session-raise",
               dispatch_to: self()
               # :executor deliberately omitted
             )

    refute File.exists?(lock),
           "a start that raised after claiming must not leave the journal claimed"
  end

  test "discarding a torn tail refuses anything it cannot prove is torn" do
    journal = DurableTruth.journal_path("torn-refusal")
    token = owned(journal)
    {records, _model} = DurableTruth.history(11, 6, "session-torn-refusal")
    Enum.each(records, fn record -> assert :ok = Journal.append(journal, record, token) end)

    # A complete journal is never truncated, whatever offset is offered.
    assert {:error, {:not_torn, ^journal}} = Journal.discard_torn_tail(journal, 0, token)
    size = File.stat!(journal).size
    assert {:error, {:not_torn, ^journal}} = Journal.discard_torn_tail(journal, size, token)
    assert File.stat!(journal).size == size

    File.open!(journal, [:append, :binary], fn io -> IO.binwrite(io, <<0, 1, 2>>) end)
    torn_size = File.stat!(journal).size

    # An offset that is not the one read/1 reports is refused, so a caller cannot
    # cut a journal at a place of its own choosing.
    assert {:error, {:torn_offset_moved, ^journal, _tail, 0}} =
             Journal.discard_torn_tail(journal, 0, token)

    assert File.stat!(journal).size == torn_size

    assert :ok = Journal.discard_torn_tail(journal, size, token)
    assert {:ok, ^records, :complete} = Journal.read(journal)
  end

  test "records from another session, epoch, or sequence are rejected" do
    # The generated histories only ever carry the expected session, so the property
    # above cannot reach these paths however strong its comparison is -- a reducer
    # that admitted a foreign session passed every seed. Identity invariants need
    # records the generator will not produce, so they are asserted directly.
    {records, _model} = DurableTruth.history(3, 6, "expected")
    assert {:ok, state} = Session.replay("expected", records)

    intruder = %{kind: :session_opened, seq: state.seq + 1, session_id: "intruder", epoch: 99}

    assert {:error, {{:session_mismatch, "intruder", "expected"}, _at}} =
             Session.replay("expected", records ++ [intruder])

    stale = %{kind: :session_opened, seq: state.seq + 1, session_id: "expected", epoch: 0}

    assert {:error, {{:epoch_not_monotonic, 0, _current}, _at}} =
             Session.replay("expected", records ++ [stale])

    # The EQUAL-epoch boundary, which the generated histories cannot reach: the
    # generator always emits epoch + 1, and the stale case above only tests zero.
    # Changing the reducer from > to >= therefore passed every seed while admitting
    # a repeated epoch -- two incarnations claiming the same one, which is exactly
    # what monotonicity exists to prevent. A boundary that no generator visits has
    # to be asserted at the boundary.
    repeated = %{
      kind: :session_opened,
      seq: state.seq + 1,
      session_id: "expected",
      epoch: state.epoch
    }

    assert {:error, {{:epoch_not_monotonic, _same, _current}, _index}} =
             Session.replay("expected", records ++ [repeated])

    # One past the current epoch is the only accepted step.
    advanced = %{
      kind: :session_opened,
      seq: state.seq + 1,
      session_id: "expected",
      epoch: state.epoch + 1
    }

    assert {:ok, %{epoch: next}} = Session.replay("expected", records ++ [advanced])
    assert next == state.epoch + 1

    out_of_order = %{kind: :fact_committed, seq: state.seq + 7, fact: "skipped ahead"}

    assert {:error, {{:out_of_sequence, _detail}, _index}} =
             Session.replay("expected", records ++ [out_of_order])
  end

  test "a journal truncated at any byte replays to an intact prefix" do
    session_id = "session-truncation"
    {records, _model} = DurableTruth.history(31, 24, session_id)
    journal = DurableTruth.journal_path("truncation")
    token = owned(journal)

    Enum.each(records, fn record -> assert :ok = Journal.append(journal, record, token) end)

    assert {:ok, ^records, :complete} = Journal.read(journal)

    bytes = File.read!(journal)

    # Concept: the expected count is derived, never transcribed.
    #
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
    token = owned(journal)

    for value <- [self(), make_ref(), fn -> :ok end, %Loopex.Session{}] do
      assert {:error, {:invalid_record, :not_plain_data}} =
               Journal.append(journal, %{kind: :fact_committed, seq: 1, fact: value}, token)
    end

    assert {:error, {:invalid_record, :missing_kind}} =
             Journal.append(journal, %{seq: 1}, token)

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
