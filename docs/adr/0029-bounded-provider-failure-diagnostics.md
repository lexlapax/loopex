<a id="concept"></a>
## Concept

Technical depth: [Bounded provider failure diagnostics](0029-bounded-provider-failure-diagnostics-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-11
- **Decision owner:** Maintainer
- **Supersedes:** 0019, only its closed ambiguous-terminal fields and restriction on host observation of child diagnostics, as specified below
- **Prerequisite for:** Implementation of bounded provider failure diagnostics in M3

<a id="concept-adr-0029-decision"></a>
### Purpose and Decision

A failed real provider call currently returns one conservative classification.
That protects credentials and retry authority, but cannot distinguish transport,
provider-response and stream, decoder or internal failures. Host tracing cannot
recover a cause already discarded inside the separate companion VM. A passing
supplemental call does not explain or disposition an earlier failure.

The actual same-source companion will send one finite failed-stage/category
pair through its existing private terminal channel. Advance the private codec
and handshake to version 2. Only the ambiguous-failure terminal gains the closed
map; other result variants retain their fields. The finite vocabulary includes
seven stages, typed provider and transport categories, and truthful fallback
classes. Its standalone encoded map fits 256 bytes within unchanged frame and
semantic limits. The first unsuccessful stage wins after that stage's finite
classifier precedence; an outer generic fallback cannot overwrite it.

The public Model result remains `dispatched_or_unknown` with
`"model_call_failed"`. The pair never affects dispatch, retry, accounting,
settlement, permit retirement or cleanup authority. Raw reasons, exception
terms, provider structures, strings from provider output and credentials remain
excluded from host diagnostics and every other prohibited plane.

Technical depth: [Finite terminal contract](0029-bounded-provider-failure-diagnostics-technical.md#technical-adr-0029-decision).

<a id="concept-adr-0029-lifetime"></a>
### Ownership and Observable Behavior

The existing invocation guardian retains the validated pair provisionally.
Only a single valid terminal followed by clean EOF seals it for observation.
An intervening duplicate, malformed or additional frame, partial final frame,
or child/channel loss discards the provisional pair. A valid category is not
cleanup proof; cleanup evidence stays separate.

One private observation point exposes the sealed pair to existing test-owned
static tracing. No production observer is installed. Normal invocations discard
the pair with their guardian; a bounded test collector may retain the fixed
pair in failure diagnostics and remains responsible for its own termination.
Missing or invalid evidence is unavailable, never an inferred cause.

No new public API, callback option, storage, logger output, socket, service,
application, dependency or production tracing is added. The instrumented
experiments' private files and event histories are not part of this design.

Technical depth: [Lifetime and failure handling](0029-bounded-provider-failure-diagnostics-technical.md#technical-adr-0029-lifetime).

<a id="concept-adr-0029-compatibility"></a>
### Compatibility and Rollback

The host and companion remain one same-source build pair. Mixed version-1 and
version-2 artifacts refuse before credential delivery; no dual decoder or silent
downgrade is introduced. Rollback restores the matching older pair and loses
these diagnostics. It changes no session record and grants no retry of an
uncertain invocation.

This new successor record preserves ADR 0019's accepted bytes. Its descriptor,
credential isolation, namespace and cleanup contracts remain unchanged, as do
ADR 0018's generic result and raw-data prohibitions. Codec version 1 is the
current implementation value, not a literal frozen by ADR 0019.

Technical depth: [Supersession and compatibility](0029-bounded-provider-failure-diagnostics-technical.md#technical-adr-0029-compatibility).

<a id="concept-adr-0029-evidence"></a>
### Evidence, Budget and Alternatives

Use finite secret-bearing synthetic causes to prove classification without
retaining secrets, and real companion fixtures to prove framing, sealing,
invalid-evidence rejection and cleanup. Requalify affected actual same-source
provider and CLI paths; supplemental instrumented binaries cannot substitute.
No historical failure is waived, and no subsequent pass explains it by itself.

Growth is limited to the existing adapter, worker, codec, bridge and their tests.
The concrete proposed file list intersects no current M0–M3 Bound Artifacts
row. The listed ordinary version-fixture updates are not named locked selectors
and need no standalone override. The named M2 adapter witness retains both its
pre-canary refusal and post-canary generic ambiguity guarantees. Stop for the
applicable approval before changing any locked claim, witness name, deadline or
count, bound bytes or approved limit.

Owned-socket observation is an alternative requiring no product change. It can
show connection attempts and established connections, but not provider status,
TLS alerts or application failure categories. Permanent fixed-category reporting
is selected for useful evidence from the actual required companion.

Technical depth: [Proof inventory and alternative](0029-bounded-provider-failure-diagnostics-technical.md#technical-adr-0029-evidence).

<a id="concept-adr-0029-authority"></a>
### Authority and Implementation Boundary

The maintainer approved this bounded design; the ADR remains Proposed pending
exact-candidate acceptance. Implementation depends on review and acceptance of
this successor ADR and the corresponding M3 proposal/rebind record. A design
choice does not accept unseen bytes, waive an observed failure, authorize
additional supplemental calls or close M3. Preserve ADR 0019's acceptance and
historical records rather than editing them in place.

Technical depth: [Authority and scope](0029-bounded-provider-failure-diagnostics-technical.md#technical-adr-0029-authority).

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
