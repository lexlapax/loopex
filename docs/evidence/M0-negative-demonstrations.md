# M0 Negative Demonstrations

A test that still passes when the behavior it covers is removed proved nothing,
and no locked name or minimum count detects that. For each constitutional
outcome this records the mechanism disabled, the resulting failure, and the
commit at which it was demonstrated.

Populated as outcomes 4, 5, and 6 are proved.

## Outcome 4 — journal replay

- mechanism disabled: `resolve_tail/2` in `Loopex.Coordinator`, made to return `:ok` for a torn tail instead of discarding it, so recovery extends a journal whose reader still stops at the tear
- observed failure: `a fact acknowledged after torn-tail recovery survives the next restart` failed on `assert "after the tear" in survived` — the fact was present while the coordinator ran and absent after the restart
- demonstrated at: the commit adding the repair, reverted before commit and confirmed byte-identical by SHA-256

The demonstration above targets the mechanism a review found missing. An earlier,
blunter one disabled the durable write in `Journal.append/2` entirely and drove
`journal_replay_test.exs` to 4/7 passed, with the locked test failing on
`assert Session.facts(recovered) == Session.facts(before)`, `left: []` against
`right: ["workspace opened", "wrote a", "workspace closed"]`. It is kept here as
history, but it proves less: removing all appends fails almost any journal test,
whereas the recorded demonstration fails only because recovery stopped repairing
the tear.

One property in this outcome has no negative demonstration by design. Interior
corruption and a corrupted length prefix must *not* be repaired, and that is
asserted by refusal — the journal's byte size is unchanged after a refused repair.
A demonstration that removed the refusal would destroy data rather than fail a
test, so the assertion is the evidence.

## Outcome 5 — fencing and reconciliation

- mechanism disabled: `Loopex.Session.fence/2`, made to always return `:open`
- observed failure: `fencing_test.exs` fell to 4/7 passed; the locked test failed on the fence assertion with `left: :open` against the expected `{:fenced, "b992e523…"}`
- demonstrated at: `8047a7a`, reverted before commit and confirmed byte-identical

The fence assertion is the earliest to trip, so that run halted before reaching
the dispatch-count assertion in the same test. The count would also have failed —
with the fence disabled, op-2 and op-3 dispatch, making four dispatches rather
than two — but this record states the failure that was actually observed rather
than the one that would have followed.

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
