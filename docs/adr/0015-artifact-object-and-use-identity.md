# 0015. Artifact object and use identity

<a id="concept"></a>
## Concept

Technical depth: [Reference algebra, compatibility, and evidence](0015-artifact-object-and-use-identity-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-08-31
- **Decision owner:** Maintainer
- **Prerequisite for:** proposed `M2` Amendment 4
- **Supersedes:** 0009

The supersession is limited to ADR 0009's fixed five-member artifact-reference
shape, its rule that identical bytes return an equal full reference, its closed
`put/3`, `fetch/2`, and `stat/2` callback set, the accepted free-form metadata
input, and the lookup-probe form used to resolve an opaque locator. This decision
changes `fetch/2` to take object identity, changes `stat/2` to take an opaque
locator, adds `describe/2` for use identity, and closes the metadata schema. Its
one shipped adapter, content integrity, bounded model-facing notice, pinning,
collection, placement, and no-implicit-read decisions remain unchanged.

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

The shipped local adapter already stores one digest-addressed object, but it and
the test-only adapter preserve only the reserved `media_type` and `role` members
inside the same five-field reference; every other caller label is discarded.
Core validates exactly those five members and rejects an adapter answer that
adds provenance, so neither implementation has a truthful place to return one.
A locator-only retrieval constructs a syntactically valid reference with
invented digest, size, media type, and role merely to call `stat/2`.

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
object. Within one adapter namespace, an object locator is permanently bound to
at most that one digest/size pair and is never reassigned after collection; an
old locator therefore resolves its original object or unavailable, never newer
bytes. Each admitted retention also stores one immutable use record beside the
object. The compact artifact reference carries the object triple, `media_type`,
`role`, the use record's canonical-encoding version, digest, and fixed
digest-derived locator; it does not inline the potentially large provenance.

The core-owned `Loopex.ArtifactStore.put/3` facade normalizes the caller's closed
provenance record before any adapter sees it. The reserved keys `media_type` and
`role` become top-level reference members. The exact required use labels
`session_id`, `run_id`, `operation_id`, `attempt`, and `tool_call_id` remain
together in the private use record. The four identifiers stay lossless opaque
non-empty binaries, including invalid UTF-8 and control bytes already admitted
by their source contracts, and `attempt` stays an arbitrary positive integer.
No adapter may discard, reinterpret, or merge one admitted caller label with
another use of the same object. Unknown metadata keys are refused rather than
copied into any durable or public plane.

The use record carries `LoopexProtocol.Canonical.version/0`, and the use digest
is computed over that version, the complete object triple including its opaque
locator, and the exact normalized use. The compact reference repeats the version
so recovery selects the retained encoding before it verifies the digest.
Its public use locator is exactly `"use:" <> use_digest`; it is derived from
the digest and cannot be chosen by an adapter to encode private provenance.
Different normalized provenance yields a different use digest; repeating the
same bytes, provenance, object identity, and encoding version may reuse the same
immutable use record.
Pinning and collection treat one referenced object plus every immutable use
record named by a live receipt as one reachability obligation. An object cannot
remain valid while a referenced use sidecar is collected; both stay retained
through the receipt's retry and recovery window.
Use publication is atomic and convergent. Concurrent retention of the same
object and exact normalized use converges on the same digest-derived locator and
identical complete bytes; no caller returns success while a partial, replaced,
or conflicting sidecar is observable.
The canonical use encoding is bounded at 131,072 bytes. That ceiling is large
enough for the existing 1,024-byte executor identifiers plus a tool-call
identifier already retained inside one 65,536-byte Store item, with deterministic
encoding overhead. It is a distinct artifact-use admission boundary: a larger
otherwise-valid source identifier is refused as `artifact_use_too_large`, and
the spill reports retention failure rather than claiming that an artifact was
retained. A scalar-size lower-bound check refuses an obviously oversized opaque
identifier or attempt before canonical encoding allocates its output; values
that pass that allocation guard still face the exact encoded-byte ceiling.

The core-owned `stat/2` facade takes an opaque object locator and returns object
facts only, and requires the returned object's locator to equal the locator it
asked for. It never invents or recovers use labels. `describe/2` takes the
validated compact artifact reference, projects its fixed use locator, validates
the returned immutable use record against the reference's use digest, and
returns the exact private provenance. The core-owned `fetch/2`
accepts a validated object or artifact reference, projects its object identity,
reads by the opaque object locator, and verifies exact digest and size before
returning bytes. The public retrieval facade therefore performs `stat(locator)`
followed by `fetch(object)` and constructs no fake reference.

The runtime journals and publishes the compact validated artifact reference
returned for that spill. It preserves the adapter's opaque object locator,
derives the use locator only from the use digest, never inlines use metadata,
and never asks `stat/2` to reconstruct the caller's reason for retaining it.
The fixed use-locator encoding reveals no raw use member. Recovery or an authorized host can resolve that reason through
`describe/2` without turning opaque identifiers into public safe text.

Metadata is canonical closed provenance, not a free-form side channel. Invalid,
missing, unknown, or over-ceiling use data is refused before success.
No credential-designated or arbitrary-note member exists. Production derives
the five admitted provenance values from already validated runtime and job
identity and never supplies a credential as metadata; a direct caller cannot
smuggle a sixth `note` or `credential` key through `put/3`. Opaque identifiers
remain opaque, so the contract makes no false claim that their arbitrary byte
content can be distinguished from coincidentally equal secret bytes.

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
must preserve immutable normalized use records and implement locator-only
`stat/2` plus use-locator `describe/2`. They must also make object locators
non-reusable for the lifetime of an adapter namespace, by deterministic
content-derived naming or a durable used-locator tombstone/index. Existing five-member development
references carry no trustworthy use provenance and fail closed as unavailable
when read; every new write emits the eight-member compact form. Stored objects
need no migration because their content address and bytes do not move. M2 is
unreleased, so no public compatibility promise is withdrawn by refusing those
development-only records.

Rolling back the code can still read the immutable object files directly, but
the prior five-member validator cannot recover a receipt carrying the new
eight-member reference. Development histories written under this decision become
unavailable to the prior runtime and may be discarded; they are not silently
decoded with metadata missing. This is still not an object-byte migration,
because the content-addressed files themselves are unchanged.
If ADR 0016's receipt-fitting path is also implemented, rollback first removes
that path's eight-member-reference reservation and consumer, or removes both
decisions atomically. Restoring the five-member validator while the ADR 0016
consumer remains is not a deployable intermediate state.

Acceptance of this ADR alone changes no M2 plan or gate byte. `M2` Amendment 4
must declare it as a closure prerequisite and lock the evidence below before
dependent implementation or closure.

`M2` does not close until the reusable adapter suite proves object deduplication
and immutable use preservation independently, the runtime proves the compact use
reference reaches its durable receipt and public event while opaque provenance
remains privately resolvable through `describe/2`, and malformed metadata,
locator resolution, use-record absence, and integrity failure all fail closed.

Technical depth: [Compatibility, rollback, and evidence](0015-artifact-object-and-use-identity-technical.md#technical-adr-0015-consequences).

## Links

- [ADR 0009 — Tool, executor, and grant contracts](0009-tool-executor-and-grant-contracts.md#concept)
- [M2 technical plan](../plans/M2-technical.md#technical-depth)
- [Vision sessions, storage, and artifact boundary](../vision-technical.md#technical-vision-sessions-storage)
