# 0015. Artifact object and use identity

<a id="concept"></a>
## Concept

Technical depth: [Reference algebra, compatibility, and evidence](0015-artifact-object-and-use-identity-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-08-31
- **Decision owner:** Maintainer
- **Prerequisite for:** `M2` closure
- **Supersedes:** 0009

The supersession is limited to ADR 0009's fixed five-member artifact-reference
shape, its rule that identical bytes return an equal full reference, and the
lookup-probe form used to resolve an opaque locator. Its one shipped adapter,
content integrity, bounded model-facing notice, pinning, collection, placement,
and no-implicit-read decisions remain unchanged.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |

<a id="concept-adr-0015-context"></a>
## Context

ADR 0009 uses one map for two different facts. The digest, size, and locator
identify stored bytes. The media type, logical role, session, and tool call
describe why one caller retained those bytes. Content addressing requires the
first set to be equal for identical bytes; auditability requires the second set
to survive even when two uses share one object.

The shipped local adapter already stores one digest-addressed object, but it
drops caller metadata and returns the same five fields for every use. The
test-only adapter instead retains the last caller's labels and returns them from
`stat`, so the two implementations disagree. Core then projects exactly five
members and drops anything an adapter did preserve. A locator-only retrieval
constructs a syntactically valid reference with invented digest, size, media
type, and role merely to call `stat/2`.

The accepted equality rule therefore makes truthful per-use provenance
impossible, and the lookup probe makes an object query pretend to know use
metadata it cannot know. This is a cross-adapter and durable-record contract,
so it is corrected additively rather than by choosing one implementation's
accident.

Technical depth: [The conflated identities](0015-artifact-object-and-use-identity-technical.md#technical-adr-0015-context).

<a id="concept-adr-0015-decision"></a>
## Decision

**One artifact has an object identity and each retention has a use identity.**
The object is the exact triple `digest`, `size`, and opaque `locator`. Storing
identical bytes twice yields the same object triple and one immutable stored
object. A use reference carries that triple plus `media_type`, `role`, and a
bounded `metadata` map. Two references to the same object are equal only when
their normalized use metadata is also equal.

The core-owned `Loopex.ArtifactStore.put/3` facade normalizes the caller's closed
provenance record before any adapter sees it. The reserved keys `media_type` and
`role` become top-level reference members. The exact required use labels
`session_id`, `run_id`, `operation_id`, `attempt`, and `tool_call_id` remain
together under `metadata`. The adapter callback receives only that normalized
use record. No adapter may discard, reinterpret, or merge one admitted caller
label with another use of the same object. Unknown metadata keys are refused
rather than copied into a durable or public plane.

The core-owned `stat/2` facade takes an opaque locator and returns object facts
only. It never invents or recovers use labels. The core-owned `fetch/2` accepts
a validated object or use reference, projects its object identity, reads by the
opaque locator, and verifies exact digest and size before returning bytes. The
public retrieval facade therefore performs `stat(locator)` followed by
`fetch(object)` and constructs no fake reference.

The runtime journals and publishes the exact normalized use reference returned
for that spill. It does not replace the locator with the digest, remove
metadata, or ask `stat/2` to reconstruct the caller's reason for retaining it.

Metadata is canonical closed provenance, not a free-form side channel. The four
identifiers are the exact identifiers already carried by the executor job and
receipt, `attempt` is a positive bounded integer, and the canonical metadata
encoding is at most 2,048 bytes. This boundary applies the artifact-reference
safe-text rule: valid UTF-8, non-empty, within the field ceiling, and containing
no control, format, line-separator, or paragraph-separator codepoint.
Invalid, missing, unknown, or oversized metadata is refused before success.
Host-resolved credentials and arbitrary caller notes have no member in this
shape and therefore cannot enter an artifact reference through `put/3`.

Technical depth: [Normative shapes and callbacks](0015-artifact-object-and-use-identity-technical.md#technical-adr-0015-decision).

<a id="concept-adr-0015-alternatives"></a>
## Alternatives

**Make use metadata part of the object key.** Identical bytes retained by two
tool calls would be stored twice and cease to be content-addressed. This spends
storage to avoid naming the two identities and is not taken.

**Keep only the latest metadata beside the object.** A later caller would
rewrite what an earlier durable receipt meant. Recovery could then display the
wrong session or call provenance for an immutable object. Not taken.

**Return full use references from `stat`.** A locator can name stored bytes but
cannot identify which of several uses the caller meant. Choosing one would
fabricate provenance; returning all would change a lookup into an index. Not
taken.

**Carry arbitrary bounded metadata.** A byte ceiling would limit size but still
create a new path from a caller-controlled string into journals, public events,
and artifacts, including a resolved credential supplied as a note. The closed
provenance schema retains every admitted use label without creating that
side-channel. Not taken.

Technical depth: [Alternative costs](0015-artifact-object-and-use-identity-technical.md#technical-adr-0015-alternatives).

<a id="concept-adr-0015-consequences"></a>
## Consequences

The artifact-store callback shape changes on an unreleased surface. Adapters
must preserve normalized use metadata and implement locator-only `stat/2`.
Existing five-member development references carry no trustworthy use
provenance and fail closed as unavailable when read; every new write emits the
six-member form. Stored objects need no migration because their content address
and bytes do not move. M2 is unreleased, so no public compatibility promise is
withdrawn by refusing those development-only records.

Rolling back the code can still read the immutable object files directly, but
the prior five-member validator cannot recover a receipt carrying the new
six-member reference. Development histories written under this decision become
unavailable to the prior runtime and may be discarded; they are not silently
decoded with metadata missing. This is still not an object-byte migration,
because the content-addressed files themselves are unchanged.

`M2` does not close until the reusable adapter suite proves object deduplication
and use preservation independently, the runtime proves the exact use reference
reaches its durable receipt and public event, and malformed metadata, locator
resolution, and integrity failure all fail closed.

Technical depth: [Compatibility, rollback, and evidence](0015-artifact-object-and-use-identity-technical.md#technical-adr-0015-consequences).

## Links

- [ADR 0009 — Tool, executor, and grant contracts](0009-tool-executor-and-grant-contracts.md#concept)
- [M2 technical plan](../plans/M2-technical.md#technical-depth)
- [Vision sessions, storage, and artifact boundary](../vision-technical.md#technical-vision-sessions-storage)
