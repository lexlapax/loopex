# 0009. Attachment, cursor, retention, and session residency

<a id="concept"></a>
## Concept

Technical depth: [Attachment, cursor, and residency mechanics](0009-attachment-cursor-and-residency-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-08-22
- **Decision owner:** Maintainer
- **Prerequisite for:** `M2` acceptance, and implementation of its outcomes 4, 5, 6, and 8

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |

<a id="concept-adr-0009-context"></a>
## Context

`M1` has one attached caller whose lifetime is the session's lifetime. Attachment
state is runtime-local, a cursor is a position in committed durable public-event
history, and an overflowing attachment is disconnected with its last stable
position. All of that is correct at N=1 and underspecified at N.

Three questions have no current answer.

**Does a cursor survive a daemon restart?** In `M1` the runtime restart is the
session restart, so the question does not arise. In `M2` a client holds a cursor
across a daemon it does not control.

**How much history is retained?** A cursor is only resolvable against history
that still exists. `M1` never had to bound this because nothing outlived the
caller.

**When does a session with zero attachments stop being resident?** `M2`'s whole
purpose is that a session outlives its client — but a daemon that never releases
a session accumulates runtimes until it dies. "Survives zero attachments" without
an eviction rule is a leak specified as a feature.

Technical depth: [Why residency is a separate question from durability](0009-attachment-cursor-and-residency-technical.md#technical-adr-0009-context).

<a id="concept-adr-0009-decision"></a>
## Decision

- **An attachment is runtime-local and never durable.** No subscriber record, no
  stored subscription, nothing to garbage-collect after a crash. A reconnecting
  client presents a cursor; it does not resume an attachment.
- **A cursor is a position in committed durable public-event history**, and
  therefore survives daemon restart by construction. It carries no authority: a
  cursor identifies a position, never a controller.
- **Retention is explicit and configured**, with a documented default. Committed
  public-event history is retained to that bound and no further guarantee is
  made.
- **A cursor older than retained history returns `cursor_expired` with a fresh
  snapshot and cursor.** Never a silent truncation and never a gap. A gap is the
  one thing the delivery contract does not permit; duplicates are permitted.
- **Paged history read is a separate read-only API** that establishes no
  subscription. Conflating read with subscribe is how a query silently becomes a
  stream and a cursor silently becomes an attachment.
- **A session with zero attachments becomes non-resident after a bounded
  configured grace period.** Eviction releases runtime resources; it changes no
  durable truth. A later attach resumes the session and serves a snapshot
  indistinguishable from one a resident session would have served.
- **Eviction is observable**, not silent. An operator and a test can both see
  that it happened and why.
- **Work in progress defers eviction.** A session with an active run is resident
  regardless of attachment count, because `M2`'s purpose is that work continues
  when the client is gone.

Technical depth: [Exact attach transaction, cursor rules, and residency states](0009-attachment-cursor-and-residency-technical.md#technical-adr-0009-decision).

<a id="concept-adr-0009-alternatives"></a>
## Alternatives

**Durable attachments** would let a client resume "its" subscription by identity
rather than by position. It is not recommended: it adds a durable record whose
only purpose is convenience, and it creates orphaned rows for every client that
never returns. A cursor already carries everything resume needs.

**Unbounded retention** removes `cursor_expired` entirely and makes every cursor
eternally resolvable. Attractive and dishonest — storage is finite, so the bound
exists whether or not it is specified, and an unspecified bound fails as a
surprise instead of as a named error.

**No eviction** keeps every session resident forever. Simplest to implement and
correct until the daemon runs out of memory, at which point it is catastrophic
and undiagnosable.

**Eviction by explicit client request only** makes residency a client decision.
Rejected because the client that should have released the session is exactly the
client that died.

Technical depth: [Alternative analysis](0009-attachment-cursor-and-residency-technical.md#technical-adr-0009-alternatives).

<a id="concept-adr-0009-consequences"></a>
## Consequences

Clients must handle `cursor_expired`. That is a real burden and it is the honest
one: the alternative is a client silently missing history.

The grace period is a tuning parameter with no universally right value. It is
configured, documented, and shortened in tests so eviction is provable rather
than assumed.

A snapshot served after eviction must be indistinguishable from one served by a
resident session. That is a strong requirement and deliberately so — if the two
differ, residency has leaked into observable behaviour, which means the daemon
has become a source of truth.

Technical depth: [Operational consequences](0009-attachment-cursor-and-residency-technical.md#technical-adr-0009-consequences).

<a id="concept-adr-0009-compatibility"></a>
## Compatibility, Migration, and Rollback

No public compatibility claim. No stored attachment or cursor record exists, so
nothing migrates. Retention and grace period are configuration with documented
defaults, changeable without a schema change.

Rollback is removing the residency policy while the daemon does not depend on it.

Technical depth: [Compatibility and rollback mechanics](0009-attachment-cursor-and-residency-technical.md#technical-adr-0009-compatibility).

## Links

- [ADR 0008](0008-session-protocol-candidate.md#concept) — the envelopes that
  carry cursors, snapshots, and `cursor_expired`
- [ADR 0010](0010-daemon-collaboration-policy.md#concept) — which attachment may
  command, given that a cursor never grants authority
- [ADR 0006](0006-store-transaction-and-owner-epoch.md#concept) — the committed
  history a cursor indexes
