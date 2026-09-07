# 0021. Compacted provider-accounting provenance

<a id="concept"></a>
## Concept

Technical depth: [Versioned settlement, replay, and evidence](0021-compacted-provider-accounting-provenance-technical.md#technical-depth).

- **Status:** Accepted
- **Date:** 2026-09-06
- **Decision owner:** Maintainer
- **Supersedes:** 0018

The supersession is limited to ADR 0018's settlement record version, the compact
result's representation and validation, and compatibility for existing
version-1 settlements. Its accounting policy, attempt opening, dispatch permit,
retry allowance, budgets, terminal selection, and other rules remain in force.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | Maintainer | [disposition](../developer/agent-context-map.md#disposition-adrs-0019-0021-2026-09-07) | candidate `b7f97092f7b6d6661e66bc775fd88195b92b67a0`; concept `sha256:ce25d99eb282c732a16d938d2385a7d75dffb30a9099183a8340a03b8a607bd4`; technical `sha256:7041508edcaeaa53a39647cf524fc489470f46dba08c5dfff462c297e5f010d3` |

<a id="concept-adr-0021-context"></a>
## Context

ADR 0018 retains complete validated provider usage as reported accounting even
when the canonical reply is valid but its complete settlement cannot fit Store.
Version 1 cannot explain that compact result's accounting: its exact schema has
no retained usage provenance, and the validator admits unrelated reported figures.

The same error category represents replies rejected before canonical validation.
Those have no trustworthy reported-accounting evidence and consume estimated
remaining allowance. Treating both alike loses accepted reported-usage behavior
or lets replay admit an arbitrary reported pair. This needs a private record
version, not a different provider-reconciliation or budget policy.

Technical depth: [The missing durable distinction](0021-compacted-provider-accounting-provenance-technical.md#technical-adr-0021-context).

<a id="concept-adr-0021-decision"></a>
## Decision

**New writes use `model_attempt_settled_v2`. An unreadable result distinguishes
absence of validated evidence from a validated reply omitted solely because its
complete settlement exceeded Store admission.**

Without validated evidence it retains an explicit `none` shape and uses estimated
remaining allowance. Settlement compaction retains a bounded, versioned evidence
map containing the canonical reply's normalized usage and the exact Store
admission observation that required omission. Complete reported usage stays
reported and must equal the settlement's accounting pair. Unreported usage stays
estimated. No other unreadable result can carry reported accounting.

The map is retained provenance, not independent proof of its origin. Replay
checks shape, limits, and usage/accounting equality. Live-writer evidence must
prove the usage and refusal observation came from the same validated canonical
reply and intended full settlement. No digest of a discarded reply is introduced:
without its preimage that digest adds no replay proof.

Replies that fit remain retained exactly as ADR 0018 defines. Compaction never
reconstructs the discarded reply or adds a provider call, invoice claim, budget
change, retry, or public field. Attempt-open version 1 and its two-attempt limit
stay unchanged. Version 2 can settle an already open version-1 attempt without
redispatch; the new writer always writes version-2 settlements.

The new reader accepts unambiguous version-1 history under the old rules. It
refuses only the previously admissible version-1 `unreadable_model_answer` with
reported accounting, whose missing usage provenance cannot be recovered. Those
sessions become unavailable to the new reader; other valid version-1 sessions
remain replayable. No committed figure is silently rewritten as estimated.

Technical depth: [Version-2 representation and validation](0021-compacted-provider-accounting-provenance-technical.md#technical-adr-0021-decision).

<a id="concept-adr-0021-alternatives"></a>
## Alternatives

**Version the compact evidence and narrowly refuse ambiguous legacy history** is
recommended. It preserves known usage and strengthens replay validation without
changing effect authority, at the cost of one private schema and the stated
legacy-session restriction.

**Estimate every unreadable reply** is smaller but reverses ADR 0018 combination
5 and can consume more run allowance than its known usage requires.

**Keep version 1 or grandfather ambiguous reported pairs** preserves availability
but explicitly accepts accounting without retained corroborating usage. It does
not repair that historical validation gap.

**Retain the full reply or a new artifact reference** avoids discarding its
preimage but the full settlement does not fit; an artifact adds a retention and
failure boundary absent from this repair. Raw provider data is not replay truth.

**Rewrite legacy accounting** changes committed budgets and later decisions.
**Version attempt-open too** adds authority states without changing authority.
Neither is selected.

Technical depth: [Alternative costs](0021-compacted-provider-accounting-provenance-technical.md#technical-adr-0021-alternatives).

<a id="concept-adr-0021-consequences"></a>
## Compatibility, Delivery, and Rollback

Mixed history permits a version-1 prefix followed by version-2 settlements;
replay rejects a later downgrade to version 1. A session containing version
2 needs a reader that understands it. An older reader must refuse before becoming
ready or scheduling semantic work; the existing fenced ownership-administration
step may precede that refusal. This is not a promise of a mutation-free old-binary
probe. Stop all owners and back up the complete state before rollback inspection.

Rollback to the prior binary supports only histories without version 2. A
version-2 session remains unavailable to it. No journal rewrite, provenance
reconstruction, or Store-object migration is authorized. Commit-unknown identity
and settlement/terminal atomicity remain unchanged. The compact evidence never
enters conversation, public events, or rendered output.

M2 stays Closed. This proposal authorizes no implementation, integration, gate
change, or release. Adding its tests to M2's frozen gate needs the separate
Closed-gate generation transaction; supplemental evidence does not advance a lock.

Technical depth: [Rollback and decisive evidence](0021-compacted-provider-accounting-provenance-technical.md#technical-adr-0021-consequences).
