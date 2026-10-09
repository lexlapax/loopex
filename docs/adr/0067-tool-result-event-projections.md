<a id="concept"></a>
## Concept

Technical depth: [Tool result event projection mechanics](0067-tool-result-event-projections-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-10-09
- **Decision owner:** Maintainer
- **Proposed amendments:** [ADR 0023](0023-experimental-public-session-protocol.md#concept), only the closed `tool.finished` wire payload; [ADR 0044](0044-run-model-and-reasoning-configuration.md#concept), only that payload in the complete current foreground `/3` and daemon `/4` manifests; [ADR 0045](0045-model-originated-questions.md#concept), only the transport projection of its existing original tool terminal result.

<a id="concept-adr-0067-decision"></a>
### Purpose and proposed decision

A client must receive the terminal result the session actually committed. Core
already emits a tool terminal without an executor operation member for model
questions, policy refusals, validation failures and calls lacking a retained
executor receipt. Both transports currently require an executor operation ID
and a null reason on every `tool.finished`. Answering a real model question
therefore closes its daemon attachment before the client can receive the
interaction terminal. Moving malformed requests to another socket would leave
this failure intact.

Accept two mutually exclusive, closed payload variants of the existing event:

1. The eight-member variant keeps its existing required nonempty operation ID,
   resolved tool ID, null reason and bounded artifact references.
2. The seven-member variant has exactly the same remaining member names, with
   `operation_id` absent, artifacts exactly empty, tool ID either the actual
   resolved ID or null, and reason either null or exact valid UTF-8 text of at
   most 131,072 bytes. Both variants keep the existing six-value outcome union,
   opaque identity encoding and envelope quantities. The enclosing record and
   existing Core admission bounds still apply.

The seven-member variant reports a result without an operation identity in
that public event. It does not prove that no operation exists or that nothing
ran: an unproved dispatched effect also uses this existing Core shape. Its
outcome, uncertainty, original identity and reconciliation obligations remain
unchanged. Absence never grants authority to retry or creates a grant, job,
receipt, artifact or new operation identity. Reasons retain their existing
public provenance and content-protection obligations; this decision adds no
private diagnostic or credential capture allowance.

Use one shared protocol codec for the two transports and independently authored
Node decoding and vectors. Replace both complete current manifest definitions,
recompute and independently pin both schema digests, and update their clients
together. Keep Core records, native events, transactions, clocks, event order,
controller authority and delivery custody unchanged. The original same-socket
malformed and stale-epoch refusals, question settlement and duplicate-command
proofs remain required.

Technical depth: [Producer inventory and closed grammar](0067-tool-result-event-projections-technical.md#technical-adr-0067-decision).

<a id="concept-adr-0067-alternatives"></a>
### Alternatives and recommendation

Recommend the separate seven- and eight-member variants. They preserve the
actual event shapes while keeping the receipt-backed variant's refusal of
non-null reasons, missing operation identity and private members.

A single shape with an optional operation member and a nullable tool ID can
represent the same facts, but an unrestricted combination would also admit
receipt-like events carrying free-form reasons or artifact-bearing events
without an operation member. Constraining every combination reduces it to the
two variants above. Supplying null or a synthesized operation ID on every event
would change Core truth or invent evidence. Suppressing the tool terminal or
its reason would lose an already committed result. Those alternatives are not
selected.

Technical depth: [Alternative mechanics and limits](0067-tool-result-event-projections-technical.md#technical-adr-0067-alternatives).

<a id="concept-adr-0067-evidence"></a>
### Observable consequences and proof

Text, choice and decline answers remain visible through the controller socket,
including their original tool result, exact durable answer, command digest and
historical duplicate admission. Policy denials, unresolved tools and unproved
executor results retain truthful terminal observations across both transports.
Malformed public events still detach at the existing emitted cursor and retain
active output custody until its original completion.

Proof must join literal positive and negative vectors, both complete manifests,
independent Node decoding, both real transport paths and the existing Core
uncertainty and recovery cases. Preserve the original cases, actors, cleanup
joins, cutoffs and private-capture refusals. A green codec suite alone cannot
complete this transport obligation.

Technical depth: [Required evidence and confinement](0067-tool-result-event-projections-technical.md#technical-adr-0067-evidence).

<a id="concept-adr-0067-compatibility"></a>
### Compatibility and rollback

This changes the current experimental payload contract and both complete schema
digests. Retain the server-specific names `loopex.experimental/3` and
`loopex.experimental/4` under the pre-1.0 current-contract policy, replacing
their current assets and client pins together. Clients with prior digest pins
refuse before session work; add no fallback decoder, automatic downgrade or
mutation replay. Native journal and outbox bytes remain unchanged, so there is
no data migration. Reverting the transport changes must not rewrite retained
terminal facts or claim the model-question transport proof still holds.

This pair is Proposed. Its exact acceptance must precede dependent schema,
codec and client implementation. It neither closes M7 nor accepts a test waiver.

Technical depth: [Current-contract replacement mechanics](0067-tool-result-event-projections-technical.md#technical-adr-0067-compatibility).

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
