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
| 0008 | Owner succession recovery and runtime placement | Accepted | [Decision](0008-owner-succession-recovery-and-runtime-placement.md#concept) | [Technical depth](0008-owner-succession-recovery-and-runtime-placement-technical.md#technical-depth) |
| 0009 | Tool, executor, and grant contracts | Accepted (partially superseded by 0012, 0015, and 0016) | [Decision](0009-tool-executor-and-grant-contracts.md#concept) | [Technical depth](0009-tool-executor-and-grant-contracts-technical.md#technical-depth) |
| 0010 | Provider continuation and exact context staging | Accepted (partially superseded by 0013, 0017, and 0018) | [Decision](0010-provider-continuation-and-context-staging.md#concept) | [Technical depth](0010-provider-continuation-and-context-staging-technical.md#technical-depth) |
| 0011 | Session input algebra and streaming progress | Accepted (partially superseded by 0012, 0013, 0014, 0016, 0017, and 0018) | [Decision](0011-session-input-algebra-and-streaming.md#concept) | [Technical depth](0011-session-input-algebra-and-streaming-technical.md#technical-depth) |
| 0012 | Executor cancellation capability | Accepted (partially superseded by 0016) | [Decision](0012-executor-cancellation-capability.md#concept) | [Technical depth](0012-executor-cancellation-capability-technical.md#technical-depth) |
| 0013 | Run-deadline commitment at first request staging | Accepted (partially superseded by 0017) | [Decision](0013-run-deadline-commitment-at-first-request-staging.md#concept) | [Technical depth](0013-run-deadline-commitment-at-first-request-staging-technical.md#technical-depth) |
| 0014 | Stream closure at owner loss | Accepted (partially superseded by 0018) | [Decision](0014-stream-closure-at-owner-loss.md#concept) | [Technical depth](0014-stream-closure-at-owner-loss-technical.md#technical-depth) |
| 0015 | Artifact object and use identity | Accepted | [Decision](0015-artifact-object-and-use-identity.md#concept) | [Technical depth](0015-artifact-object-and-use-identity-technical.md#technical-depth) |
| 0016 | Configured cancellation observation | Accepted | [Decision](0016-configured-cancellation-observation.md#concept) | [Technical depth](0016-configured-cancellation-observation-technical.md#technical-depth) |
| 0017 | Durable context and record admission budgets | Accepted | [Decision](0017-durable-context-admission-budget.md#concept) | [Technical depth](0017-durable-context-admission-budget-technical.md#technical-depth) |
| 0018 | Provider attempt authority and recovery | Accepted | [Decision](0018-provider-attempt-authority-and-recovery.md#concept) | [Technical depth](0018-provider-attempt-authority-and-recovery-technical.md#technical-depth) |
| 0019 | Experimental public session protocol | Proposed | [Decision](0019-experimental-public-session-protocol.md#concept) | [Technical depth](0019-experimental-public-session-protocol-technical.md#technical-depth) |
| 0020 | Durable interaction lifecycle and host-policy authority | Proposed | [Decision](0020-durable-interaction-lifecycle-and-host-policy-authority.md#concept) | [Technical depth](0020-durable-interaction-lifecycle-and-host-policy-authority-technical.md#technical-depth) |

0001 and 0002 were the prerequisites that unblocked the first milestone
candidate; the [plans register](../plans/README.md) records current status.
0003 blocks nothing — it settles the questions a first publication would
foreclose, so that they stay open until there is evidence to decide them.
0006 and 0007 are the prerequisites for accepting `M1`. 0006 decides how a
store refuses a stale session owner; 0007 decides what a local executor validates
before an effect. Both must be dispositioned before `M1` is accepted, not merely
before the outcomes they govern are implemented.

0008 is an implementation-time prerequisite for revising `M1` Workstream A and
then completing Workstream B. It supplies the durable identity ADR 0006's
dead-owner recovery requires and makes M1's active-passive runtime-placement
boundary explicit without adding an active-active coordination claim.

0009, 0010, and 0011 are the prerequisites for accepting `M2`. 0009 decides what
a tool definition is, how a runtime-scoped registry resolves one, which built-in
tools ship, how oversized tool output leaves through an artifact port, and how a
host says no; 0010 decides what a turn's canonical model request contains, how
the durable conversation is journaled and replayed, which project resources may
enter it, and when a run stops; 0011 decides which inputs a running session
admits, how steering and queued follow-up work are ordered and journaled, and
how a turn streams without letting transient progress become durable truth. All
three must be dispositioned before `M2` is accepted, not merely before the loop
they govern is implemented.

0012 supersedes only ADR 0009's `execute/4` exclusivity and ADR 0011's claim
that `execute/5` was the whole executor-boundary change; the remaining decisions
in both ADRs stay in force. 0013 supersedes only ADR 0010's and ADR 0011's
absolute-deadline-at-admission or promotion clauses; their remaining provider,
staging, input, and streaming decisions stay in force. 0014 supersedes only ADR
0011's universal stream-closure obligation where the transient plane's owner
dies or loses authority before it can state a truthful disposition and count,
and its rule that every closure precedes the attempt outcome's publication,
solely where a terminal fact commits before handoff and its reply reaches the
originating coordinator afterwards. ADR 0011's domain, sequencing,
loss-detection, and durable-fallback rules stay in force.

0015 separates immutable artifact-object identity from the bounded metadata of
each use, so content deduplication cannot erase durable provenance. It narrowly
supersedes ADR 0009's conflated object/use reference and callback shapes. 0016
derives core cancellation observation and the later command backstop from the
one configured cleanup period, narrowly superseding the executor-boundary and
cleanup clauses it names in ADR 0009, ADR 0011, and ADR 0012. 0017 establishes
distinct durable context-token and Store-record admission ceilings and narrowly
supersedes the staging, prompt-admission, and terminal-projection clauses it
names in ADR 0010, ADR 0011, and ADR 0013. 0018 establishes one-use
current-owner provider dispatch, an exact two-attempt version-1 allowance, and
conservative non-redispatching recovery, narrowly superseding the provider
attempt and owner-loss retry clauses it names in ADR 0010, ADR 0011, and ADR
0014. All four are accepted prerequisites for proposed `M2` Amendment 4;
acceptance does not itself amend the M2 plan pair or gate, authorize dependent
implementation, close M2, or authorize integration or release.

0019 and 0020 are proposed for the headless application protocol milestone,
whose retained draft is the [`M4` plan](../archive/M4.md). 0019 decides the experimental
public session protocol and its first stdio mapping; 0020 decides durable
interaction and policy resumption without turning an answer into a grant.
Neither is a prerequisite for `M3`, and neither is accepted. The JSON codec
decision drafted beside them was withdrawn: the runtime floor `M3` raises puts
Elixir's standard-library `JSON` module inside the toolchain, so no external
codec dependency is proposed.

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
