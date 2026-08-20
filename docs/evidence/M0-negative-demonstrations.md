# M0 Negative Demonstrations

A test that still passes when the behavior it covers is removed proved nothing,
and no locked name or minimum count detects that. For each constitutional
outcome this records the mechanism disabled, the resulting failure, and the
commit at which it was demonstrated.

Populated as outcomes 4, 5, and 6 are proved.

## Outcome 4 — journal replay

- mechanism disabled: `resolve_tail/3` in `Loopex.Coordinator`, made to return `:ok` for a torn tail instead of discarding it, so recovery extends a journal whose reader still stops at the tear
- observed failure: `a fact acknowledged after torn-tail recovery survives the next restart` failed — the fact was present while the coordinator ran and absent after the restart
- demonstrated at: `676b2b3d41391a830728ea8293325c281c101351`, reverted before commit and confirmed byte-identical by SHA-256 of `apps/loopex/lib/loopex/coordinator.ex` (`18b3b7846f1c0887723c7c74f3b7752ef29110d99ea0505460ec6b91d053899b`)

This demonstration was re-taken. It previously named `resolve_tail/2` and located
itself at "the commit adding the repair", which is prose rather than a revision a
reviewer can resolve. The function is arity 3 since the claim became an argument
to it, so the recorded demonstration described bytes that no longer existed, and
under the rule that relevant byte changes invalidate affected evidence it had to
be run again rather than renamed.

Two further demonstrations cover the claim-release mechanism in this outcome.
They are recorded in their own section below rather than here, because the gate
requires exactly one field set per outcome and that lock is not mine to amend:
its purpose is to stop a populated field sitting beside an unfilled one inside a
single record, which a separate section does not defeat. The record above remains
this outcome's one complete demonstration.

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

## Additional demonstrations — outcome 4 claim release

Not an outcome section. These cover the claim-release mechanism, which a review
found missing after the outcome 4 record above was written. Same format, kept
outside the numbered sections so the locked one-per-outcome rule still holds.

### The failing return path

- mechanism: the `Journal.release_session/2` call on the failing path of `Coordinator.init/1`, removed, so a start that claims the journal and then stops leaves the sentinel behind
- observed failure: `a coordinator refuses to start on a corrupt journal rather than repairing it` failed on `refute File.exists?(lock)`
- demonstrated at: `676b2b3d41391a830728ea8293325c281c101351`, reverted before commit and confirmed byte-identical by SHA-256 of `apps/loopex/lib/loopex/coordinator.ex` (`18b3b7846f1c0887723c7c74f3b7752ef29110d99ea0505460ec6b91d053899b`)

### The raising path

- mechanism: `:dispatch_to` and `:executor` moved back to being fetched inside `start_claimed/5`, i.e. after the claim, so a caller omitting one raises with the sentinel already created
- observed failure: `a start that raises on a missing option must not leave the journal claimed` failed on `refute File.exists?(lock)`
- demonstrated at: `61914a6`, reverted before commit and confirmed byte-identical by SHA-256 of `apps/loopex/lib/loopex/coordinator.ex` (`578c3cf998b8188026645f154817a3576116ce1a11145da1c57c2aefa483ab80`)

This second path is why the first fix was incomplete. `gen_server` does not call
`terminate/2` when `init/1` raises any more than when it returns `{:stop, _}`, and
two required options were still read after the claim, so a missing key stranded
the sentinel through a path the `{:stop, _}` test could not reach. Every required
option is now read before the claim.

What these do NOT establish: both fail inside one VM only because the assertion
looks at the lock file directly. The consequence that makes the defect serious --
a session that cannot start at all after a VM restart, because the recorded OS pid
is no longer this process and the owner cannot be proved dead -- is not reachable
from a single-VM suite, and is argued from the takeover rule rather than shown.
