<a id="concept"></a>
## Concept

Technical depth: [Compaction activity payload and ownership](0054-compaction-activity-progress-technical.md#technical-depth).

- **Status:** Accepted
- **Date:** 2026-10-06
- **Decision owner:** Maintainer
- **Proposed amendments:** [ADR 0043](0043-context-compaction-checkpoint.md#concept), only the exact transient compaction-progress projection; [ADR 0011](0011-session-input-algebra-and-streaming.md#concept), only the additional compaction domain and its activity-only, unclosed observation rule.
- **Constrained by:** [ADR 0014](0014-stream-closure-at-owner-loss.md#concept), current-owner admission and loss semantics; [ADR 0044](0044-run-model-and-reasoning-configuration.md#concept), coordinated current wire generations; the [pre-1.0 current-contract rule](../developer/agent-context-map.md#disposition-pre1-current-contract-2026-10-02).

<a id="concept-adr-0054-context"></a>
### Purpose and current gap

Technical depth: [Current source and authority](0054-compaction-activity-progress-technical.md#technical-adr-0054-context).

Let an attached caller observe that compaction maintenance received permission
for a summary attempt, without disclosing summary text or treating activity as
checkpoint evidence. Automatic run-owned maintenance and an explicit compact
command need the same bounded projection.

ADR 0043 and the accepted M7 plan require transient
`context.compaction_progress` but do not define its payload or producer.
Current maintenance deliberately discards provider deltas. The active-maintenance
view is durable and carries captured configuration and bounds; it supplies no
private stage stream. Neither surface may fill this gap with its own schema.

<a id="concept-adr-0054-decision"></a>
### Proposed decision

Technical depth: [Exact closed payload and derivation](0054-compaction-activity-progress-technical.md#technical-adr-0054-decision).

Use one six-member activity observation: kind, episode identity, actual run or
compact owner, opaque stream-domain identity, sequence zero and durable base
event sequence. The kind is `context.compaction_progress`. It has no activity
variant: receiving the record means only that the current coordinator received
a positive permit-dispatch result for the bound summary attempt. It does not
prove entry into the provider, billing, progress toward completion or success.

Derive the domain from the already committed session, maintenance operation and
attempt with the new domain kind `compaction`. Do not allocate or persist another
identity. Each permitted retry or further summary has its own domain. An episode
and its owner correlate those observations with the existing public maintenance
view and checkpoint/completion records.

This family is a single activity observation per attempt, not a content stream.
It has no closing record, count, disposition, heartbeat or percentage. This
explicitly narrows ADR 0011's closure obligation only for the new compaction
family. Ordinary model and executor streams retain their closure rules. Missing
activity or owner loss says nothing about outcome; no client timer may infer
abandonment or completion.

<a id="concept-adr-0054-delivery"></a>
### Emission, succession and privacy

Technical depth: [Producer cuts and loss behavior](0054-compaction-activity-progress-technical.md#technical-adr-0054-delivery).

The serial session coordinator selects the committed binding. Emit at most one
observation after a positive provider-permit result, through the existing
serialized current-owner progress admission boundary and bounded transient
routing. Provider callbacks continue to discard every maintenance delta.
Preparation, negative or uncertain permit results, recovered pending attempts,
checkpoint validation and completion emit no activity observation.

A stale owner cannot emit new activity. A successor does not replay an old
observation, close an old domain or redispatch an ambiguous attempt to produce
one. A new positively permitted attempt can produce its own observation under
the existing maintenance recovery rules. The same episode can therefore be
visible in a snapshot with no received activity. Durable checkpoint and compact
completion records remain the outcome evidence.

The payload discloses only existing public ownership and episode correlation,
the opaque attempt label and its durable base. It excludes summary/input text,
private phases, source ranges, digests, usage, provider identity or routes,
instructions, credentials, permits, epochs, clocks and private recovery data.
Observation arrival can reveal activity timing; best-effort delivery is not a
secrecy guarantee or a complete activity log.

<a id="concept-adr-0054-alternatives"></a>
### Alternatives and consequences

Technical depth: [Alternative contracts and implementation cost](0054-compaction-activity-progress-technical.md#technical-adr-0054-alternatives).

1. **One activity observation, recommended.** Callers gain correlation and an
   indication of a permitted attempt. The exact six fields and no-closure rule
   avoid publishing maintenance internals. Callers use durable views for status.
2. **A phase stream with closure.** Publish preparation, summary and checkpoint
   stages with per-domain sequences and a final disposition/count. This offers
   richer UI feedback, but makes private transitions public commitments and
   requires truthful stage and closure production at cancellation, uncertain
   commit and succession cuts. It still cannot guarantee delivery or derive
   completion from silence. That larger contract is not selected here.

<a id="concept-adr-0054-activation"></a>
### Activation, compatibility and required proof

Technical depth: [Coordinated activation and verification](0054-compaction-activity-progress-technical.md#technical-adr-0054-activation).

Implement the closed native projection, both transports and independent clients
with the complete foreground generation 3 and daemon generation 4 contracts.
A codec or one manifest row does not activate a generation. Preserve existing
frame, queue, authority and deadline limits; no required check is waived.
Prove actual automatic and standalone producers, retry/domain separation,
current-owner races, uncertain dispatch/commit, owner loss, dropped progress,
privacy refusal and independent wire interpretation.

No journal, checkpoint, receipt or snapshot format changes. Current-format
restart and backup/restore remain required. Before 1.0, remove superseded current
wire readers rather than add older-client or older-root fallback. Rolling back
an unactivated implementation may restore the prior source; after activation,
a different served payload requires another governed current-contract decision.
Acceptance binds this exact pair and authorizes only its named implementation;
it is not generation activation, milestone closure or publication.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | Maintainer | [disposition](../developer/agent-context-map.md#disposition-m7-compaction-activity-2026-10-06) | candidate `3c33a2ca875f94c0b41ea7ca92900d4c9084e90a`; concept `sha256:c7628948485d90b660b7e19609862267a2a1c675e51dd828739ed227e226fe74`; technical `sha256:a75fa09ba62fa465373f5761ba3b4a74652b3674834b837bbc48106b709d5e8e` |
