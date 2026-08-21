# Architecture Decisions

Decisions that refine the vision, recorded where evidence had to choose among
valid designs. Part of the [documentation index](../README.md).

An ADR is not milestone-scoped. It is numbered, flat, and permanent: superseding
a decision adds a new record rather than rewriting the old one.

## Decisions

| # | Decision | Status | Concept | Technical depth |
| --- | --- | --- | --- | --- |
| 0001 | Repository and application layout | Accepted | [Decision](0001-repository-and-application-layout.md#concept) | [Technical depth](0001-repository-and-application-layout-technical.md#technical-depth) |
| 0002 | Bootstrap runtime floor and version matrix | Accepted | [Decision](0002-bootstrap-runtime-floor.md#concept) | [Technical depth](0002-bootstrap-runtime-floor-technical.md#technical-depth) |
| 0003 | Extension contract boundary and distribution constraints | Accepted | [Decision](0003-extension-contract-boundary.md#concept) | [Technical depth](0003-extension-contract-boundary-technical.md#technical-depth) |
| 0004 | Plan amendment and supersession | Proposed (parked) | [Decision](0004-plan-amendment-supersession.md#concept) | [Technical depth](0004-plan-amendment-supersession-technical.md#technical-depth) |
| 0005 | Milestone supersession | Proposed (parked) | [Decision](0005-milestone-supersession.md#concept) | [Technical depth](0005-milestone-supersession-technical.md#technical-depth) |
| 0006 | Store transaction contract and owner epoch | Accepted | [Decision](0006-store-transaction-and-owner-epoch.md#concept) | [Technical depth](0006-store-transaction-and-owner-epoch-technical.md#technical-depth) |
| 0007 | Local executor grant, job, and receipt | Accepted | [Decision](0007-local-executor-grant-job-receipt.md#concept) | [Technical depth](0007-local-executor-grant-job-receipt-technical.md#technical-depth) |

0001 and 0002 were the prerequisites that unblocked the first milestone
candidate; the [plans register](../plans/README.md) records current status.
0003 blocks nothing — it settles the questions a first publication would
foreclose, so that they stay open until there is evidence to decide them.
0006 and 0007 are the prerequisites for accepting `M1`. 0006 decides how a
store refuses a stale session owner; 0007 decides what a local executor validates
before an effect. Both must be dispositioned before `M1` is accepted, not merely
before the outcomes they govern are implemented.

0004 and 0005 are both parked. They designed correction paths for a defect
found in an accepted plan, then the defect that prompted them turned out to be
on an unmerged branch that could simply be abandoned. They become relevant the
first time such a defect is found after integration.

## How a Decision Is Recorded

Each ADR is a Concept and Technical depth pair that forms one decision. The
Concept file owns context, the decision, alternatives, consequences,
compatibility, and the governance record; its companion owns invariants,
mechanics, and evidence. Acceptance binds both files as they existed at the
recorded candidate.

Status is `Proposed` or `Accepted` and lives in the Concept file. Those are the
only two values the repository check accepts, because an accepted pair is
anchored across history and its bytes are never edited afterwards. A decision is
replaced additively: the successor declares `Supersedes: NNNN` and the
predecessor stays exactly as accepted. No actor accepts its own decision: acceptance is an explicit
maintainer or recorded-delegate disposition, captured in the governance record
rather than inferred from a status word.

The [`adr` skill](../../.agents/skills/adr/SKILL.md) carries the procedure for
preparing or revising one. A reversible implementation choice is recorded in the
nearest code, test, or plan progress instead — an ADR is for a decision among
valid designs, never an activity log.

## Related

- [Vision](../vision.md#concept) — the founding authority these decisions refine.
- [Developer documentation](../developer/README.md) — method and routing.
- [Plans](../plans/README.md) — milestone register and lifecycle.
