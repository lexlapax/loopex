<a id="technical-depth"></a>
## Technical depth

Concept: [Milestone purpose and outcomes](M1.md#concept).

<!-- loopex:plan-technical-envelope:start -->
## Normative Technical Envelope

<a id="technical-plan-prerequisites"></a>
### Prerequisites and Acceptance Points

Concept: [Milestone scope](M1.md#concept-plan-scope).

Concept: [Milestone non-goals](M1.md#concept-plan-non-goals).

Two decisions block implementation and are unresolved at opening. Neither may be
settled inside this plan, and acceptance is blocked while either is open.

**ADR 0003 — durable store port and record schema.** Owns what a store
implementation must guarantee, what a record carries, and how a stale writer is
refused. M0 left one race explicitly deferred here: reading the ownership
sentinel and performing the write are separable, so a window remains in which
ownership changes between the check and the mutation. The accepted decision must
say whether records carry an owner epoch that replay refuses, or whether the port
requires transactional exclusion from every implementation. That choice
determines whether `Loopex.Journal` becomes an adapter behind the port or is
replaced by one. Outcome 3 cannot be implemented before it is accepted.

**ADR 0004 — executor grant and effect boundary.** Owns what a grant contains,
who mints it, and what an executor validates before any effect. The Product
Non-Negotiables already fix that executors validate audience, operation, attempt,
digest, lease, expiry, and fence, and that host policy alone owns allow, deny,
and defer; the ADR fixes the concrete shape those take and the lifetime of a
lease. Outcome 6 cannot be implemented before it is accepted.

Accepted and unchanged: ADR 0001 repository and application layout, ADR 0002
bootstrap runtime floor. This milestone proposes no change to either.

Acceptance points. The maintainer or a recorded delegate accepts both normative
envelopes and the gate's canonical bytes together, and accepts ADR 0003 and ADR
0004 before implementation of outcomes 3 and 6 respectively. A deferral of any
outcome requires an explicit approved limitation recorded in the Concept plan
rather than a silent narrowing of the gate.

<a id="technical-plan-ownership"></a>
### Ownership, Decision Owners, and Rejoin Barriers

Concept: [Milestone scope](M1.md#concept-plan-scope).

One integrator owns rejoin, conflicts, the candidate SHA, and post-rejoin
verification. Decision owners: the maintainer owns ADR 0003 and ADR 0004,
scope deferral, gate weakening, evidence waiver, and closure.

Rejoin barriers, in order:

1. **Workstream A rejoins first.** Outcomes 1 and 2 fix how a runtime and a
   session are started and owned. Every other workstream depends on that shape,
   and starting them earlier means building against a startup contract that has
   not settled.
2. **Workstream B rejoins before C's executor work.** The store port decides how
   a stale writer is refused, and the executor's fencing evidence is meaningless
   against a store that cannot refuse one.
3. **Workstream D rejoins last** and may not begin before A and B are integrated,
   because an end-to-end demonstration over an unsettled boundary demonstrates the
   boundary rather than the loop.

No workstream may create an alternate session loop, a private authority path, or
a competing durability truth to avoid a barrier. Parallel writers require declared
non-overlapping ownership, distinct branch namespaces, and separate working
directories and state roots.

<a id="technical-plan-evidence"></a>
### Evidence Obligations and Mapping

Concept: [Milestone outcomes](M1.md#concept-plan-outcomes).

Evidence is claim-proportional. Each outcome maps to the class its claim requires,
and a green command is necessary but never sufficient.

| # | Obligation |
| --- | --- |
| 1 | Two runtimes started in one VM with distinct state roots, neither reachable through a global name, and a negative test proving a runtime reference is required rather than inferred |
| 2 | Property tests over generated session histories, plus process kills at every durable transition, plus a negative demonstration that a second coordinator cannot own a live session |
| 3 | A reusable store conformance suite that every implementation runs, plus fault injection at every durable transition, plus a demonstration that a stale writer's records are refused at replay with the mechanism ADR 0003 fixes |
| 4 | Contract tests at the boundary proving committed events, transient progress, and diagnostics are distinct planes, and that no caller can obtain durable truth through a progress or diagnostic channel |
| 5 | One real provider call from an explicitly invoked lane, with non-secret provider, model, and endpoint class retained; an absent credential reports evidence unavailable rather than skipping |
| 6 | A negative corpus in which each of audience, operation, attempt, digest, lease, expiry, and fence is individually invalid and individually refused, plus one real controlled execution |
| 7 | The reference client drives the loop through the embedded API only, proved by a test that fails if the client reaches past the API to session state |
| 8 | A counting collector proving exactly one dispatch ever carried each effect across both runtime incarnations, and that every acknowledged fact survives the restart |

Every negative demonstration is retained with the milestone: the mechanism
disabled, the resulting failure, and the revision it was demonstrated at, each
recorded once per outcome in the format the gate runner requires.

<a id="technical-plan-compatibility"></a>
### Compatibility

Concept: [Milestone scope](M1.md#concept-plan-scope).

No public compatibility claim is made or frozen. The embedded API is a semantic
contract for one attached caller in this milestone, not a released surface, and
nothing here is labelled stable, release-candidate, or experimental as a public
contract.

The store port and the executor protocol are designed to be replaceable and carry
reusable conformance suites, but their shapes may change until a milestone claims
compatibility with schemas, vectors, independent consumers, and upgrade evidence.

<a id="technical-plan-migration"></a>
### Migration and Rollback

Concept: [Milestone scope](M1.md#concept-plan-scope).

There is no installed base and no released artifact, so no migration path is owed
to a prior version. What is owed is a rollback path for the repository itself:
every workstream lands behind a green gate on both locked toolchain pairs, and a
reverted commit returns the tree to a state whose gate is green.

M0's retained evidence is not migrated. It remains bound to M0's closed record,
and this milestone's evidence is taken independently at its own candidate.

<a id="technical-plan-packaging"></a>
### Packaging

Concept: [Milestone scope](M1.md#concept-plan-scope).

No package is published, installed, or versioned for distribution. The umbrella
layout, dependency direction, and toolchain floor from ADR 0001 and ADR 0002 are
unchanged, and core remains stdlib and OTP only.

Any new dependency requires the ordinary dependency decision before use, and the
dependency budget check enforces the direction rather than trusting review.

<a id="technical-plan-minimalism"></a>
### Proportional Minimalism Budget

Concept: [Milestone scope](M1.md#concept-plan-scope).

The gate must fail because the working loop does not exist, never because a
checker, registry, or document is missing. No outcome here adds a repository
check, and none may be satisfied by adding one.

Every proposed abstraction names the concrete implementations it unifies before
it exists. At opening, exactly two are justified: the **store port**, which
unifies the M0 journal with at least one further implementation exercised by the
conformance suite, and the **executor boundary**, which separates a controlled
local tool from the coordinator that may never run one directly. A third
abstraction requires a recorded reason naming its second implementation.

Speculative single-use layers stay out. Anything that can live in an adapter, a
client, or a host without weakening the kernel stays out of core. Raw line count
is a review signal and not a pass condition; the measured size of the product code
is recorded at closure so a reader can weigh it, and no run passes or fails on it.
<!-- loopex:plan-technical-envelope:end -->
