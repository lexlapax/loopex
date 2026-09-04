# 0020. Durable interaction lifecycle and host-policy authority

<a id="concept"></a>
## Concept

Technical depth: [Interaction mechanics](0020-durable-interaction-lifecycle-and-host-policy-authority-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-08-24
- **Decision owner:** Maintainer
- **Prerequisite for:** `M4` acceptance

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |

<a id="concept-adr-0020-context"></a>
## Context

ADR 0009 already declares `allow`, `deny`, and `defer` on the host-policy
callback. M2 deliberately maps a returned `defer` to
`interaction_unsupported`, because it has no durable interaction state. An
external app-server therefore cannot yet ask its operator about an effect while
a task is running. Adding a prompt at the wire alone would be unsafe: a
transport reply could be mistaken for authority, disappear on process loss, or
race an abort or deadline without a durable winner.

M4 needs a session-owned interaction that survives the app-server process and
returns an operator answer to host policy. The answer is evidence for a new
policy decision; it is never a grant.

Technical depth: [Missing durable decision point](0020-durable-interaction-lifecycle-and-host-policy-authority-technical.md#technical-adr-0020-context).

<a id="concept-adr-0020-decision"></a>
## Decision

- A policy `defer` commits one pending interaction before
  `interaction.requested` publishes. The owning tool decision and run suspend,
  and no executor intent or process starts.
- M4 activates ADR 0009's existing callback branch; it does not widen the
  callback return. The locked M2 one-shot `Loopex.Policy.decide/2` projection
  continues to turn `defer` into `interaction_unsupported`. A separately named
  interaction-aware evaluator admits a validated `defer` only for the
  session-owned M4 lifecycle and re-enters the same host callback with one
  bounded `interaction_response` field after an answer commits.
- The coordinator creates a durable opaque `interaction_id` distinct from every
  request, command, session, run, turn, tool-call, operation, and attempt
  identity. The retained record binds the original bounded policy request and
  digest, interaction-request and answer digests, bounded policy identity and
  revision, exact bounded choice request, creation instant, effective expiry,
  and status; it
  carries no grant, credential, PID, function, or policy implementation term.
- `respond_interaction` is an ordinary durable session command keyed by
  `(session_id, command_id)`. It records one bounded answer against exactly one
  pending interaction. Admission means the answer committed, not that an effect
  is allowed.
- Host policy re-evaluates the original request with the recorded answer. The
  retained `policy_request_digest`, `interaction_request_digest`, and
  `answer_digest` stay distinct; no fourth resolution-request digest is
  introduced. Only a committed `allow` result may supply ADR 0009's
  bounded grant reference; grant binding and effect intent commit before
  dispatch. Denial, malformed policy output, timeout, or failure dispatches
  nothing.
- Identical replay of a response command returns its historical admission;
  changed content under the same command ID conflicts. A different command for a
  resolved, expired, aborted, mismatched, or absent interaction is refused with
  a stable reason.
- Another `defer` resolves the current interaction and creates a fresh
  interaction ID. At most one interaction is pending for the serial tool
  decision, and the run's absolute deadline remains the outer bound.
- Response, expiry, abort, deadline, and policy resolution races are decided by
  journal order. Expiry resolves the policy decision as denial and mints no
  grant; it does not add a new run-terminal outcome. Abort and deadline retain
  ADR 0009/0010 cancellation, `bound_reached`, and `outcome_unknown` precedence.
- Recovery reconstructs a recorded answer and resumes policy evaluation. A
  crash between answer admission and resolution leaves the run suspended; no
  recovery branch speculates, acknowledges permission, or dispatches first.
- Snapshots and durable events expose enough pending and resolved interaction
  state for a new app-server process to resume the question. Transport loss by
  itself changes no interaction state.
- Policy implementation selection is trusted host launch configuration. No
  protocol method, session parameter, model value, project resource, answer, or
  other client content selects a policy implementation or changes its profile.

Technical depth: [Exact state and race contract](0020-durable-interaction-lifecycle-and-host-policy-authority-technical.md#technical-adr-0020-decision).

<a id="concept-adr-0020-alternatives"></a>
## Alternatives

- **Treat the answer as a grant.** Rejected because content and interaction do
  not own authority; only host policy may allow an effect.
- **Keep the question in the app-server process.** Rejected because a process
  loss would lose admitted work or silently choose an outcome.
- **Map expiry to a new run-terminal outcome.** Rejected because the existing
  denial and deadline algebra already state what happened without widening the
  founding terminal set.
- **Generalize M4 into a workflow/question engine.** Rejected because the only
  proven producer is policy `defer`.

<a id="concept-adr-0020-consequences"></a>
## Consequences

An operator can answer a policy question after an app-server restart without
creating authority in the transport. The coordinator gains a durable interaction
state and recovery path, and policy gains a second evaluation carrying bounded
answer evidence. Runs may stay suspended until answer, expiry, abort, or
deadline resolves the question.

Technical depth: [Evidence consequences](0020-durable-interaction-lifecycle-and-host-policy-authority-technical.md#technical-adr-0020-consequences).

<a id="concept-adr-0020-compatibility"></a>
## Compatibility, Migration, and Rollback

The interaction records add private session format. There is no installed base:
M2 evidence roots need not be migrated, and an M2 binary is not promised to open
an M4 root containing interactions. Before closure, rollback removes interaction
admission, policy re-evaluation, and their records together. A later persisted-
data promise requires an explicit migration decision.

Technical depth: [Format and rollback](0020-durable-interaction-lifecycle-and-host-policy-authority-technical.md#technical-adr-0020-compatibility).

## Links

- [ADR 0009](0009-tool-executor-and-grant-contracts.md#concept)
- [ADR 0010](0010-provider-continuation-and-context-staging.md#concept)
- [ADR 0011](0011-session-input-algebra-and-streaming.md#concept)
- [M4 Concept plan](../archive/M4.md#concept)
