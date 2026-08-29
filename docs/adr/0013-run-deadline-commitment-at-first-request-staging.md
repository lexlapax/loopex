# 0013. Run-deadline commitment at first request staging

<a id="concept"></a>
## Concept

Technical depth: [Deadline records, recovery, and evidence](0013-run-deadline-commitment-at-first-request-staging-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-08-29
- **Decision owner:** Maintainer
- **Prerequisite for:** `M2` closure
- **Supersedes:** 0010
- **Supersedes:** 0011

The two supersession declarations are limited to when a run's absolute deadline
instant becomes durable and to ADR 0011's requirement that a promotion record
duplicate the successor's inherited bounds. Promotion still decides the whole
successor run atomically; its deterministic reducer transition inherits those
bounds instead of repeating them in the terminal record. Every other decision
in ADR 0010 and ADR 0011 is incorporated unchanged.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |

<a id="concept-adr-0013-context"></a>
## Context

[ADR 0010](0010-provider-continuation-and-context-staging.md#concept) says all
three run bounds are committed with the run and describes the wall-clock bound
as an absolute instant computed at prompt admission. [ADR 0011](0011-session-input-algebra-and-streaming.md#concept)
extends that rule to a queued follow-up: promotion commits the absolute instant
in the same transaction that ends the prior run.

Both transactions have durable identities that recovery must re-present
byte-identically. Reading a wall clock inside either record makes its bytes a
function of when they are rebuilt. After an unknown commit, the same command or
terminal transition can then present different bytes under the same transaction
identity, and the Store correctly refuses to resolve it.

The Store does not stamp a commit instant. Adding one changes the persistent
transaction schema and every Store implementation under
[ADR 0006](0006-store-transaction-and-owner-epoch.md#concept). `M2` instead
keeps admission and promotion deterministic by committing the declared duration
as literal prompt data or as a deterministic follow-up inheritance, then fixes
the absolute instant in the first staged model request, whose own identity
already covers that instant.

This rule applies to every new run. The earlier proposal named only promoted
follow-ups, but a prompt follows the same two-step path: command admission commits
`deadline_ms`, and its first request commits the absolute deadline. A crash in
either pre-staging window has the same bounded consequence.

Technical depth: [The conflicting records and the shared pre-staging window](0013-run-deadline-commitment-at-first-request-staging-technical.md#technical-adr-0013-context).

<a id="concept-adr-0013-decision"></a>
## Decision

**Run admission commits a duration; first request staging commits the absolute
instant.** A prompt's admitted command carries the new run's `max_turns`,
`token_budget`, and positive `deadline_ms`. A follow-up's promotion transaction
deterministically assigns the successor the active run's already committed
declared bounds, including `deadline_ms`. The terminal record does not duplicate
those inherited values. Neither admission path commits an absolute deadline.

When that run stages its first model request, the coordinator computes
`deadline = now + deadline_ms`, includes the instant in the canonical request,
and commits it with `model_request_committed`. That transaction fixes the
deadline. Every later model request, executor job, timer, bound check, terminal
record, and recovering owner uses the same committed instant without recomputing
it.

Before the first staged-request commit, the run has no absolute deadline to
expire. If an owner dies after prompt admission or follow-up promotion but before
that commit, the successor stages the request with the full declared duration.
The outage is therefore not charged to the run. The generosity is bounded to one
pre-staging phase: several owner losses can lengthen that phase, but the first
successful request commit ends it permanently. After staging, downtime counts
exactly as ADR 0010 requires.

Maximum turns and cumulative token budget remain fully decided at admission or
promotion. A promoted follow-up inherits all three declared bounds together;
this decision changes only the wall-clock bound's conversion from a duration to
an instant.

Technical depth: [Record shapes and recovery invariant](0013-run-deadline-commitment-at-first-request-staging-technical.md#technical-adr-0013-decision).

<a id="concept-adr-0013-alternatives"></a>
## Alternatives

**Compute the instant in prompt admission and follow-up promotion.** This is the
literal ADR 0010/0011 rule, but it makes replayed transaction bytes depend on a
new clock reading. It is not safe without a durable commit timestamp. Not taken.

**Add a Store-stamped commit instant.** This preserves the original deadline
semantics and is the conforming long-term design. It changes ADR 0006's
persistent transaction contract, every Store adapter, fault-injection evidence,
and migration and rollback mechanics. It is a larger decision than `M2` and is
not taken here.

**Track active elapsed time across owners.** This avoids charging outages at any
point, but requires durable spans and changes the meaning of the operator's
wall-clock deadline. Not taken.

Technical depth: [Why each alternative changes a larger contract](0013-run-deadline-commitment-at-first-request-staging-technical.md#technical-adr-0013-alternatives).

<a id="concept-adr-0013-consequences"></a>
## Consequences

A prompt-admitted or promoted-but-unstaged run receives its full configured
duration when staging eventually succeeds. An operator may therefore observe a
run finish later than admission or promotion time plus `deadline_ms` by exactly
the time spent in that one pre-staging window. Once the first request commits,
the advertised deadline is absolute and reaches model work, executor work,
recovery, and terminal reporting unchanged.

The private journal remains deterministic under command replay, promotion
recovery, and `commit_unknown`. No provider call can be made without first
committing the request and its deadline.

`M2` does not close until this decision carries recorded acceptance and evidence
proves both pre-staging windows and the post-staging no-extension rule. No
released surface or installed store is migrated.

Technical depth: [Evidence, compatibility, and rollback](0013-run-deadline-commitment-at-first-request-staging-technical.md#technical-adr-0013-consequences).

## Links

- [ADR 0010 — Provider continuation and exact context staging](0010-provider-continuation-and-context-staging.md#concept)
- [ADR 0011 — Session input algebra and streaming progress](0011-session-input-algebra-and-streaming.md#concept)
- [ADR 0006 — Store transaction and owner epoch](0006-store-transaction-and-owner-epoch.md#concept)
- [M2 recorded limitations](../evidence/M2-recorded-limitations.md)
