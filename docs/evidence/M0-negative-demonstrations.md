# M0 Negative Demonstrations

A test that still passes when the behavior it covers is removed proved nothing,
and no locked name or minimum count detects that. For each constitutional
outcome this records the mechanism disabled, the resulting failure, and the
commit at which it was demonstrated.

Populated as outcomes 4, 5, and 6 are proved.

## Outcome 4 — journal replay

- mechanism disabled: the durable write in `Loopex.Journal.append/2`, returning `:ok` after validation and framing so nothing reaches the file
- observed failure: `journal_replay_test.exs` fell to 4/7 passed; the locked test failed on `assert Session.facts(recovered) == Session.facts(before)` with `left: []` and `right: ["workspace opened", "wrote a", "workspace closed"]`
- demonstrated at: `8047a7a`, reverted before commit and confirmed byte-identical

## Outcome 5 — fencing and reconciliation

- mechanism disabled: `Loopex.Session.fence/2`, made to always return `:open`
- observed failure: `fencing_test.exs` fell to 4/7 passed; the locked test failed on the fence assertion with `left: :open` against the expected `{:fenced, "b992e523…"}`
- demonstrated at: `8047a7a`, reverted before commit and confirmed byte-identical

The fence assertion is the earliest to trip, so that run halted before reaching
the dispatch-count assertion in the same test. The count would also have failed —
with the fence disabled, op-2 and op-3 dispatch, making four dispatches rather
than two — but this record states the failure that was actually observed rather
than the one that would have followed.

## Outcome 4 — torn-tail recovery, a second demonstration

The demonstration above disables all appends, which is a blunt instrument: it
would fail almost any journal test. It does not exercise the mechanism added after
a review found that a fact acknowledged following recovery disappeared on the next
restart. This one does.

- mechanism disabled: `resolve_tail/2` in `Loopex.Coordinator`, made to return
  `:ok` for a torn tail instead of discarding it, so recovery extends a journal
  whose reader still stops at the tear
- observed failure: `a fact acknowledged after torn-tail recovery survives the next
  restart` failed on `assert "after the tear" in survived` — the fact was present
  while the coordinator ran and absent after the restart, which is precisely the
  defect
- demonstrated at: the commit adding the repair, reverted before commit and
  confirmed byte-identical by SHA-256

A third property has no negative demonstration because it is proved by refusal
rather than by a passing path: interior corruption and a corrupted length prefix
must *not* be repaired. Those are asserted directly — the journal's byte size is
unchanged after a refused repair — since a demonstration that removes the refusal
destroys data rather than failing a test.

## Outcome 6 — isolated VM load and rollback

- mechanism disabled: `load_generation/2` loaded the generation into the test VM as well as the isolated VM, which is the same-VM reload the gate names as the rejected anti-pattern
- observed failure: `apps/loopex/test/vm_code_spike_test.exs:18` — `Expected false or nil, got {:file, ~c"nofile"}`, code `refute :code.is_loaded(module)`
- demonstrated at: `7d54e8e`, reverted before commit and confirmed byte-identical by SHA-256 rather than by inspection

Three further variants were demonstrated at the same revision and are recorded
here because each fails a different assertion, which is what shows the test is
not passing for one incidental reason: loading into the manager VM instead of the
isolated VM failed `assert VmGeneration.loaded?(vm, module)`; making
`unload_generation/2` a no-op failed `refute VmGeneration.loaded?(vm, module)`;
and ignoring the generation number in `build_generation/2` failed the rollback
equality assertion with `left: 1, right: 2`.
