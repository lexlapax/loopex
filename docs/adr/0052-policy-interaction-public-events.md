<a id="concept"></a>
## Concept

Technical depth: [Policy event schemas and proof](0052-policy-interaction-public-events-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-10-05
- **Decision owner:** Maintainer
- **Proposed amendments:** [ADR 0024](0024-durable-interaction-lifecycle-and-host-policy-authority.md#concept), only the policy interaction public event payload and answer provenance; [ADR 0044](0044-run-model-and-reasoning-configuration.md#concept), only these payload definitions in its coordinated current wire generations; [ADR 0049](0049-explicit-host-configuration.md#concept), only its retained-public-event encoding promise for these policy terminal events.
- **Constrained by:** [ADR 0045](0045-model-originated-questions.md#concept), the [accepted answer-admission disposition](../developer/agent-context-map.md#disposition-m7-policy-answer-received-event-2026-10-05), and the [pre-1.0 current-contract rule](../developer/agent-context-map.md#disposition-pre1-current-contract-2026-10-02).

<a id="concept-adr-0052-context"></a>
### Purpose

Technical depth: [Current behavior and conflicts](0052-policy-interaction-public-events-technical.md#technical-adr-0052-context).

Let every caller identify the question that ended and the answer that actually
committed, even when host policy denied the effect or cancellation followed an
answer. A denial does not mean nobody answered. A numbered turn belongs to its
run; transports must not invent a second turn identity.

Current native endings retain a selected choice but omit the numbered turn and
answer command. The old literal wire schemas name an opaque turn identity and
require null answers for denial. Current policy denial can occur only after an
answer. Foreground and daemon event delivery currently pass that native payload
through, so those schemas do not describe a coherent current contract.

<a id="concept-adr-0052-decision"></a>
### Proposed decision

Technical depth: [Closed native and wire payloads](0052-policy-interaction-public-events-technical.md#technical-adr-0052-decision).

Use one question and answer vocabulary in the current wire contract. A policy
request has ten fields; every policy terminal event has nine. Both identify the
actual interaction, run, numbered turn and tool call, and explicitly name the
policy producer and choice kind. Every ending carries the actual selected
choice and answer command together, or both null when no answer committed.
Policy denial retains the answer. Expiry and cancellation preserve an answer
that committed first. Native terminal events add the turn and actual answer
command while preserving their existing resolution, selected choice and reason.
Wire terminal events use status and answer names and omit native reason.

Keep the approved distinct answer-admission event and answered open-question
view. Answer admission leaves policy reevaluation owed; terminal resolution
closes the slot. Neither answer, event nor identity grants permission. Only the
existing committed host-policy allow can authorize its separately bound effect.

This decision changes no policy callback, private answer transaction, model
question payload, run outcome, chat record or executor contract. The native and
wire schemas are distinct exact projections, with existing scalar, record and
frame bounds. Current cursor reduction validates every terminal tuple and answer
against its own prior committed question. Repeated defer still atomically closes
the old answered round before the next request.

<a id="concept-adr-0052-delivery"></a>
### Delivery and current history

Technical depth: [Reduction, encoding and activation](0052-policy-interaction-public-events-technical.md#technical-adr-0052-delivery).

Implement these projections in both transports and independent clients with the
complete foreground generation 3 and daemon generation 4 manifests. A standalone
codec does not activate a generation. Clients verify the whole selected schema
and refuse mismatches before session work. Remove superseded current readers
and mixed-vocabulary fallback paths; maintain no older-client compatibility.

Retained journals are never rewritten. Current restart and replay must derive
the same question, admitted answer, terminal event and cursor view from the
actual owning records. A root lacking the required current terminal event shape
must refuse before activation; this proposal supplies no older-root migration or
cross-version rollback. Existing current-format backup/restore obligations remain.

<a id="concept-adr-0052-alternatives"></a>
### Alternatives and consequences

Technical depth: [Alternative payloads and tradeoffs](0052-policy-interaction-public-events-technical.md#technical-adr-0052-alternatives).

1. **Consistent question and answer vocabulary, recommended.** Fixed ten-field
   requests and nine-field endings share names with answer admission. Clients
   can follow the complete answer history directly. This adds native terminal
   answer-command disclosure and requires coordinated schemas, reducers,
   projections and clients; the wire omits native reason.
2. **Use native resolution and choice names on the wire.** Seven-field requests
   and seven-field endings can retain the same truthful answer pair and turn.
   Clients must translate between those names and the already-approved answer
   admission/open-question names. This still needs a new public contract and
   native disclosure, with separate model/policy branch selection.
3. **Retain the old literal schema.** This needs a separately approved synthetic
   turn-identity recipe and a denial-rule correction. Leaving it unchanged loses
   the actual answer history and does not complete M7's current protocol.

<a id="concept-adr-0052-evidence"></a>
### Required proof and acceptance boundary

Technical depth: [Verification obligations](0052-policy-interaction-public-events-technical.md#technical-adr-0052-evidence).

Prove exact bounded encoding with independent vectors, current journal replay and
cursor histories, denial and expiry/cancel races, repeated defer, uncertain
commits, both transport projections and independent client workflows. Retain
failures and exact candidate identities; no existing narrow test result proves
this new contract. Acceptance is a maintainer decision over this exact pair.
It authorizes its named implementation only, not generation activation without
proof, milestone closure, publication or a relaxed required check.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
