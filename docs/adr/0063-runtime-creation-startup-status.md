<a id="concept"></a>
## Concept

Technical depth: [Startup observation and caller lifetimes](0063-runtime-creation-startup-status-technical.md#technical-depth).

- **Status:** Accepted
- **Date:** 2026-10-07
- **Decision owner:** Maintainer
- **Refines:** [ADR 0059](0059-responsive-creation-transactions.md#concept)'s separate startup eligibility observation. Runtime start remains dispatcher-ready; creation custody, authority, recovery and cleanup remain governed by that decision.

<a id="concept-adr-0063-purpose"></a>
### Purpose and evidence

Technical depth: [Existing startup paths](0063-runtime-creation-startup-status-technical.md#technical-adr-0063-purpose).

Reference hosts need to know that creation startup completed before publishing a
runtime or making their single initial create. Runtime start currently awaits
only dispatcher registration. Accepted ADR 0059 requires unavailable creation
while the separate startup barrier remains unresolved. Configuration, liveness
and an absent command lookup cannot prove that barrier completed.

Durable Composition promises immediate creation after successful startup, but
has no captured startup deadline. Adding a wait therefore needs an explicit host
rule. Ephemeral startup already has a caller deadline and must retain it.

<a id="concept-adr-0063-decision"></a>
### Recommended decision

Technical depth: [Closed native read](0063-runtime-creation-startup-status-technical.md#technical-adr-0063-decision).

Expose a compact native startup snapshot through Runtime and the Loopex facade.
Its closed states are starting, ready and unavailable. It reports one opaque
startup identity and the original same-VM monotonic work cutoff. Ready means the
initial creation barrier completed; it does not reserve the creation slot or
promise that a subsequent create cannot receive the existing busy refusal.
A narrower startup read is sufficient; current authored-slot busy status adds
no information needed by acquisition.

Control captures the startup identity and original 60,000-ms work cutoff once
in initialization, before scheduling startup. That same capture governs its
startup episode and remains observable after the episode ends. This makes time
before startup intake spend the original allowance. Each read uses the existing
runtime token and performs no Store operation, recovery, mutation or waiting
for startup. Caller waiting for a read is bounded separately at at most 1,000 ms;
a failed or late read supplies no readiness evidence.

<a id="concept-adr-0063-callers"></a>
### Host waiting and cleanup

Technical depth: [Acquisition and original cutoffs](0063-runtime-creation-startup-status-technical.md#technical-adr-0063-callers).

Durable Composition waits at its shared composition boundary, after owning the
runtime and before reporting success. Its new waiting rule spends only the
original Core startup cutoff returned by the first read. It never starts a new
60-second host period. An observer pins the first startup identity and cutoff;
replacement or changed facts fail acquisition rather than extending it. The
first status call has its own bounded read timeout; subsequent reads and pauses
must fit the retained cutoff. Expiry or unavailable startup enters existing
owned cleanup and reports failure, with no initial create or resume.

The separate ephemeral holder waits before publishing its runtime, using the
earlier of its already captured caller deadline and the original Core cutoff.
All existing caller, root, actor, provider and cleanup lifetimes remain. Neither
host creates a pending create queue, retries creation, renews recovery, or treats
observation as placement authority. Stop and quiesce make the snapshot unavailable.

<a id="concept-adr-0063-consequences"></a>
### Alternatives and consequences

Technical depth: [Proof and integration](0063-runtime-creation-startup-status-technical.md#technical-adr-0063-consequences).

The alternative exposes the same status read for inspection but leaves hosts
without a startup waiting gate. It explicitly drops Composition's immediate-create
promise and accepts visible cold-start unavailable refusals in CLI and daemon
workflows even when startup might complete soon. It still performs each actual
create once and cleans up a refused one-shot startup. This is a product cost,
not permission for a fallback, repeated create or automatic recovery episode.

The recommendation preserves useful initial creation while making its waiting
cost explicit. A held startup may delay durable composition until the original
Core work cutoff; teardown then uses its existing bounds. No deadline covers
all earlier adapter acquisition, and this proposal does not add one. Startup
failure remains observable and cannot publish a usable runtime. Both real host
acquisition paths, failure cleanup and unchanged early native refusals must be
proved before describing the implementation as complete.

This is a native experimental contract. It adds no wire method, generation,
configuration member or persistent format. Before 1.0 only the current contract
is maintained. Current-format restart and complete creation lineage remain
required; no old decoder or migration is introduced. Rollback of this source
change restores dispatcher-ready host behavior and its explicit unavailable
creation consequence, without changing Store data. Acceptance authorizes this
bounded implementation, not milestone closure, publication or a partial wire
generation.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | Maintainer | [disposition](../developer/agent-context-map.md#disposition-m7-creation-startup-status-2026-10-08) | candidate `16c251ad572f9907fdc7ea3cf14be71622778c28`; concept `sha256:a28aa264c9e05186c2f877c6998b07b9d82e1593fb99b34658d7b869ef584064`; technical `sha256:751549dcd11b20a7c175a8f3f6380c100eb424c708ff4e4a389c3c8be0131d2b` |
