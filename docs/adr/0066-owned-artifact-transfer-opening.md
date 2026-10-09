<a id="concept"></a>
## Concept

Technical depth: [Owned artifact transfer opening mechanics](0066-owned-artifact-transfer-opening-technical.md#technical-depth).

- **Status:** Accepted
- **Date:** 2026-10-08
- **Decision owner:** Maintainer
- **Amends:** [ADR 0028](0028-bounded-artifact-retrieval.md#concept), only the current transfer-opening callback, custody, cleanup and work-accounting contract described here.

<a id="concept-adr-0066-decision"></a>
### Purpose and proposed choices

Artifact opening must resolve the authorized use, verify the whole immutable
object and adopt its reader within one original opening deadline. Cancellation
must remain responsive while storage blocks. A failed response cannot claim
cleanup or free capacity while original work and its evidence remain uncertain.
Core owns admission and response; the ArtifactStore implementation owns paths,
verification and physical descriptors. Session journals and stored object/use
formats remain unchanged.

The following four material choices are PROPOSED together. This pair accepts
nothing and authorizes no dependent implementation:

1. Replace optional `open_transfer/4` with the whole current-only
   `reserve_transfer/3`, `open_transfer/3`, existing `read_transfer/3` and
   `close_transfer/2` capability. Reservation does no storage I/O; Core then
   permits opening. Keep the original custodian through live/retiring custody
   and one persistent, nonoverlapping close/ack observer. Select the closed
   admitted-failure result carrying reason and proved/unproved cleanup.
2. Retain the original 60,000 ms opening response and propose a separate,
   first-anchored 5,000 ms cleanup observation. Opening never waits that extra
   allowance. Another finite cleanup allowance requires an explicit change to
   this pair; existing read, fixture or lifetime limits do not select it.
3. Retain uncertain slots and original custody through late evidence. Lost
   evidence leaves the original runtime/handle unavailable and occupied unless
   an admitted surviving owner holds actual original proof. Late reclamation
   never changes an earlier failure or supplies timely success.
4. Permit the full 67,108,864-byte object with 134,217,728 payload-work bytes
   plus at most 131,073 returned metadata bytes, explicitly additional and
   counted in the unchanged 1 GiB connection allowance. Retain failed/cancelled
   charges and the 1 MiB minimum opening debit. This does not claim total kernel
   traffic or memory fits 128 MiB.

Technical depth: [Current owners and decision boundary](0066-owned-artifact-transfer-opening-technical.md#technical-adr-0066-decision).

<a id="concept-adr-0066-capability"></a>
### One current capability

Use lookup, canonical use/session verification, object verification and reader
opening share one original request, identity, clock and custody lifetime. A
bounded non-I/O reservation precedes explicit Core permission. Opening uses
that exact reservation and caller once; cancellation or expiry cannot launch
late I/O or adopt a late result. Public success stays compact and excludes
paths, private provenance and native handles. An admitted refusal reports
`{:error, %{reason: closed_reason, cleanup: :proved | :unproved}}`; unknown
accounting remains uncertainty rather than a fabricated zero work record.

A single-open alternative has fewer callbacks but must retain uncertainty until
original caller join, expired cutoff and original owner confirmation, and can
miss early cleanup observation. The proposed handshake selects that stronger
sequencing without adding a service or owner framework.

Technical depth: [Closed callback and data grammar](0066-owned-artifact-transfer-opening-technical.md#technical-adr-0066-capability).

<a id="concept-adr-0066-custody"></a>
### Original custody and truthful reclamation

The same reserve/open custodian survives adoption and normal reads. One
persistent observer per original entry serializes close/status/ack; blocked or
repeated close cannot create more actors, waiters or overlapping invocations.
Pending, live, retiring and unacknowledged proof retain the original capacity of two transfers per
attachment and four per runtime, including after attachment removal; real
job reservations share Store headroom.

Reserved/adopted retirement requires Store physical proof, completion of the
original reserve/open invocation, exact receipt acknowledgement, then completion
and joins of original custodian/observer and other acquired custody before Core
release. A conclusively never-reserved attempt has no receipt or ack: complete
its acquired invocations and exact original joins before release. Lost
registration additionally requires original custodian join, no permission,
expired original opening deadline and actual original Store-owner confirmation
of no entry. Unknown/unregistered close, exceptions, fresh monitors and successor
owners supply no such proof. Missing evidence retains occupied/unavailable
custody; links or kill requests alone do not prove physical retirement.

Technical depth: [Cancellation and terminal ordering](0066-owned-artifact-transfer-opening-technical.md#technical-adr-0066-custody).

<a id="concept-adr-0066-clocks"></a>
### Opening response and cleanup observation

Capture the original opening clock before storage queueing. All reservation,
lookup, verification, result validation and adoption spend its 60 seconds.
Opening responds independently of blocked callbacks. Cleanup spends one proposed
five-second observation anchored at first cancellation/close, or at the original
opening deadline on expiry. Equality, scheduling overrun and late queued results
are failed elapsed evidence. Repeated observation renews neither clock; late
original proof can reclaim only prospectively.

Technical depth: [Exact clock ownership](0066-owned-artifact-transfer-opening-technical.md#technical-adr-0066-clocks).

<a id="concept-adr-0066-accounting"></a>
### Explicit work and retained safety ceilings

Charge returned source bytes and conservative attempted snapshot writes once,
including failed or cancelled operations, with separately bounded returned
sidecar bytes. Lost accounting keeps conservative reservation/unavailable work,
not a refund. Count this work and emitted snapshot reads in the actual
connection's unchanged cumulative ceiling. Canonical use bytes remain at most
131,072. A single 128 MiB total-returned-byte alternative would refuse a full
64 MiB object when metadata consumes work; that consequence is not selected
silently. Existing object, verification-buffer, chunk/read, transfer-lifetime
and capacity ceilings remain unchanged.

Technical depth: [Work inventory and exact ceilings](0066-owned-artifact-transfer-opening-technical.md#technical-adr-0066-accounting).

<a id="concept-adr-0066-verification"></a>
### Required evidence

Prove the real responsive opening and cancellation path, original actor and
physical descriptor/snapshot retirement, constant observer/cardinality under
blocked and repeated close, both no-reservation routes, lost-ack uncertainty,
late single-slot reclamation, exact elapsed boundaries and conservative
accounting. Retain the full-size positive, corruption/mutation negatives, real
job headroom and all existing consumers. No implementation, native case census,
measured guarantee or passing qualification is claimed by this proposal.

Technical depth: [Complete proof obligations](0066-owned-artifact-transfer-opening-technical.md#technical-adr-0066-verification).

<a id="concept-adr-0066-compatibility"></a>
### Current-only migration and rollback

After maintainer acceptance of this exact pair, change capability detection,
callbacks, Runtime/Dispatcher/Local custody, adapters, facade and current
DTO/wire consumers together. Remove superseded `open_transfer/4`; unsupported
capability has no fetch fallback or mixed generation. Preserve put/fetch/stat/
describe, stored objects/uses and job-owned range reads. Rollback is quiescent
same-format source replacement with retained facts intact. Cumulative connection
ownership/accounting, per-read elapsed enforcement, coordinated transport
integration and real qualification remain required work.

Technical depth: [Coordinated migration mechanics](0066-owned-artifact-transfer-opening-technical.md#technical-adr-0066-compatibility).

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | Maintainer | [disposition](../developer/agent-context-map.md#disposition-m7-owned-artifact-transfer-opening-2026-10-08) | candidate `9ff86133371bce672b46651fe0c2703f1dc2fc80`; concept `sha256:5cba4952170eee24270a8e2ac8481cc7ea4becbbb4ab65e241a756685e05eda3`; technical `sha256:ea17cac5634f30f5d9d723be972a5d9f02621f0628a4b6ac807b2f87e1300f53` |
