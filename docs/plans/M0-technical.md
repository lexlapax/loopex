<a id="technical-depth"></a>
## Technical depth

Concept: [Milestone purpose and outcomes](M0.md#concept).

<!-- loopex:plan-technical-envelope:start -->
## Normative Technical Envelope

<a id="technical-plan-prerequisites"></a>
### Prerequisites and Acceptance Points

Concept: [Milestone scope](M0.md#concept-plan-scope).

Concept: [Milestone non-goals](M0.md#concept-plan-non-goals).

Accepted prerequisites, all recorded before this plan was written:

- [ADR 0001](../adr/0001-repository-and-application-layout.md#concept) fixes the
  umbrella shape, the contract application's empty dependency list, and the
  single one-way edge from runtime to contract.
- [ADR 0002](../adr/0002-bootstrap-runtime-floor.md#concept) fixes the floor
  family, the two-validated-pairs rule, and the obligation to complete the
  self-hosting transition before closure.
- [ADR 0003](../adr/0003-extension-contract-boundary.md#concept) fixes what the
  contract application contains, which constrains outcome 1.

No unresolved implementation-blocking decision exists. Three questions are
expected to arise, and each stops work at the point named:

- Selecting a durable store beyond an in-memory adapter is out of scope. If an
  experiment appears to need one, stop before adding it.
- Choosing a provider library for outcome 7 beyond the reference adapter named
  in the vision is a dependency decision. Stop before adding any dependency to
  a new application.
- Any change to the accepted toolchain pairs stops for an amendment to ADR 0002
  rather than a gate edit. The pairs were verified against the official Elixir
  compatibility table when this gate was written, not chosen from what happened
  to be installed. The floor is the lowest supported pair in the 1.17 family and
  the table offers no patch selector, so the lowest patch of each is taken.

<a id="technical-plan-ownership"></a>
### Ownership, Decision Owners, and Rejoin Barriers

Concept: [Milestone scope](M0.md#concept-plan-scope).

The maintainer is the acceptance and closure authority. No agent accepts its own
plan, gate, review, or closure candidate. One integrator owns rejoin, conflict
resolution, the candidate SHA, and post-rejoin verification.

Workstream A is serial and blocks all others: no application exists until the
scaffold does. After A rejoins, B, C, D, and E may proceed in parallel under
declared non-overlapping ownership, distinct branch namespaces, and separate
working directories or clones per writer.

Rejoin barriers:

- A rejoins when outcomes 1, 2, 3, and 9 are green and the dependency-budget
  command rejects its adversarial corpus.
- B rejoins when outcomes 4 and 5 hold across an induced restart, not merely a
  clean shutdown.
- C rejoins when outcome 6 demonstrates load and rollback in an isolated VM
  without claiming activation semantics.
- D rejoins when outcome 7 completes on the tagged lane with a recorded
  non-secret provider and model identity.
- E rejoins last. A validation migration that landed first would force
  durable-truth work to be rewritten against a moving toolchain, and it may not
  borrow review attention from B.

<a id="technical-plan-evidence"></a>
### Evidence Obligations and Mapping

Concept: [Milestone outcomes](M0.md#concept-plan-outcomes).

Evidence is claim-proportional. Outcomes 4 and 5 carry the milestone's central
claims and require property tests for the reducer and process or store fault
injection for every durable transition; a passing happy path is not evidence for
either. Outcome 5 additionally requires that a fenced unknown outcome is never
retried, proven by an assertion that no second dispatch occurs.

Outcomes 4, 5, and 6 each require a negative demonstration: the protected test
is shown to fail when the mechanism it covers is disabled. A test that still
passes with the behavior removed proved nothing, and no locked name or minimum
count can detect that.

Outcome 3 requires each locked pair to run individually. A green run on one pair
is not evidence for the other, and a green run on an unlisted pair satisfies
neither lane.

Outcome 7 runs on an explicitly invoked lane excluded from the default suite.
The credential arrives only through the environment and never enters a journal,
fixture, log, snapshot, diagnostic, or committed byte. A missing credential
reports evidence unavailable and fails the closure claim; it never reports
success, and a skipped lane is not a pass. The lane retains non-secret provider,
model, and endpoint-class identity for review.

Outcome 9 is the ADR 0001 isolation lane: core builds and passes against fakes
only, with no adapter application resolved or started, and no per-runtime state
read from application environment. Outcome 2 additionally proves the client hook
calls repository enforcement rather than duplicating it, and that the dependency
command rejects a dynamic cross-boundary reference, not only a declared one.

Outcome 3 cannot be proved by one in-process task, because a single Mix run has
one Erlang runtime. The task verifies that the running toolchain matches a
locked pair; the gate runner is invoked once per pair under that toolchain, and
both runs are recorded.

Outcome 8's replacement must preserve the history guarantees the retired
checker provided. Locked mutation-restore, merge-divergence, and
missing-artifact fixtures prove the replacement still anchors bound artifacts
across reachable history; ADR 0002 forbids dropping a tested behavior without an
explicit disposition, and this is one.

Outcome 10 is the compiled-documentation check the development contract requires
this milestone to install.

Outcome 8 requires four separable proofs: the aggregate runs to completion with
Python and `jq` shadowed; every named bridge component is gone from the tree;
the tested client-hook behaviors still block what they blocked before, proved by
executing locked fixtures rather than by a task's exit status; and the
replacement's size is measured and reported. The size figure is audit and review
material, not a pass condition.

Every outcome maps to exactly one Progress and Evidence row. A retry is
diagnostic; a failure that disappears on the same commit, seed, and environment
is a blocking flake until it is fixed or explicitly dispositioned.

<a id="technical-plan-compatibility"></a>
### Compatibility

Concept: [Milestone scope](M0.md#concept-plan-scope).

None. No package is published, no public surface is labelled, and no supported
version span is claimed. Application names remain internal, so no released
package surface is created.

Experimental code from outcomes 4 through 6 carries no compatibility promise and
may be discarded at closure.

<a id="technical-plan-migration"></a>
### Migration and Rollback

Concept: [Milestone scope](M0.md#concept-plan-scope).

The only migration is the validation lane moving from Python and `jq` to Elixir
and Mix. The named inventory is exact: `scripts/check_status.py`,
`scripts/test_check_status.py`, `scripts/check-agent-bootstrap.py`, the `python3`
invocations in `scripts/check-status.sh` and `scripts/check-agent-bootstrap.sh`,
and the `jq` invocations in `scripts/check-agent-bootstrap.sh`,
`.claude/hooks/guard-bash.sh`, `.claude/hooks/after-edit.sh`, and
`.claude/hooks/guard-filesystem.sh`.

Shell is not being removed. The enduring baseline is Git, shell and POSIX tools,
and the accepted Elixir/OTP toolchain, so a check may remain a shell entrypoint
that calls Mix.

The migration is reversible until closure: rollback restores the retired bridge,
its tests, its aggregate wiring, and the two prerequisites together. A partial
rollback that leaves a tested path silently disabled is invalid. Removing a
tested client-hook behavior instead of migrating it requires an explicit
disposition recording equivalent protection or an accepted loss.

Scaffold rollback is deletion of the applications on the implementation branch
before integration. After integration, renaming an application requires an
amendment to ADR 0001.

<a id="technical-plan-packaging"></a>
### Packaging

Concept: [Milestone scope](M0.md#concept-plan-scope).

None. This milestone produces no release, tag, package, or distributable
artifact, and its closure authorizes none.

<a id="technical-plan-minimalism"></a>
### Proportional Minimalism Budget

Concept: [Milestone scope](M0.md#concept-plan-scope).

Every abstraction introduced must name the concrete implementations it unifies.
Until a second store, provider, or executor exists, a behaviour is justified only
where the gate requires a fake to substitute for a real edge; anywhere else,
direct code is the smaller system.

The retiring bridge measures 4,313 lines across `scripts/check_status.py`,
`scripts/test_check_status.py`, `scripts/check-status.sh`, and
`scripts/check-agent-bootstrap.py` at the gate commit. The replacement reports
its own measured size and names every behavior it drops with the reason.

That figure is a review signal, not a threshold. No run passes or fails on it,
because a line ceiling rewards compressed code, hidden complexity, and deleted
coverage. An independent reviewer weighs the measurement against the
dropped-behavior list and decides whether the result is proportionate.
<!-- loopex:plan-technical-envelope:end -->
