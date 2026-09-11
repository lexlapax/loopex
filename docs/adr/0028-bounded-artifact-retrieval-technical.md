<a id="technical-depth"></a>
## Technical depth

Concept: [Bounded artifact retrieval](0028-bounded-artifact-retrieval.md#concept).

<a id="technical-adr-0028-decision"></a>
### Contract and Evidence

Concept: [Context and decision](0028-bounded-artifact-retrieval.md#concept-adr-0028-decision).

### Boundary and result

Extend the exact callback set of `Loopex.ArtifactStore` with the optional
transfer triple `open_transfer`, `read_transfer` and `close_transfer`; do not
change `Loopex.Store` or ADR 0006 journal transactions. This narrowly extends
ADR 0015's callback inventory, leaving its object/use schema and existing
callbacks intact. Legacy ArtifactStore adapters remain conformant and return
unsupported through the facade when the capability is absent.

The facade exposes the same triple: `Loopex.open_artifact_transfer(runtime,
session_id, request)` receives exactly the opaque artifact use reference, a
non-negative start offset and an optional window length; `Loopex.read_artifact_chunk(runtime,
transfer_ref, length)` returns the next sequential chunk; `Loopex.close_artifact_transfer(runtime,
transfer_ref)` releases it. Resolve authorization and ADR 0015 use identity for
that session before opening an object. Opening verifies total size and the full
SHA-256 of the immutable object in one sequential pass before any chunk exists;
the open response carries the existing object and use references, total_size,
the window bounds, object_digest and an opaque transfer reference bound to the
session and the opening connection. Each chunk carries offset, bytes and
chunk_digest; length is bounded by the accepted chunk ceiling and a chunk never
crosses the window. A window starting at total_size yields an empty transfer;
one starting beyond it refuses. No path or private tool provenance escapes
through this query family.

The ArtifactStore implementation opens the immutable object once per transfer,
validates the use binding, verifies with a 64 KiB buffer and no whole-object
accumulator, then emits chunks from the same descriptor while rejecting link
replacement and changed file identity or size around every read. Missing or
corrupt object, mismatched use, unsupported capability, invalid window,
unknown or expired transfer, and exhausted transfer or connection budgets have
distinct bounded refusals. Every open transfer owns one descriptor; close,
cancellation, connection loss and lifetime expiry release it. The existing
artifact boundary owns disk reads; core never opens paths.

### Evidence and alternatives

Test whole-object, first, last, empty and overrun windows; misuse across
sessions and connections; object-use swaps; corruption inside and outside the
requested window, which must refuse at open before any bytes; concurrent
transfers up to and beyond the budget; mutation of window bounds; close,
cancellation, connection loss, lifetime expiry and descriptor release. Measure
retained and peak memory against objects well above the chunk ceiling, and
measure bytes read per transfer: at most one complete verification plus one
sequential emit. Genuine old-format artifacts are positive controls. A
full-object read followed by binary slicing fails the memory obligation even
when the response bytes are correct.

Returning an unchecked chunk with a claimed object hash overstates integrity.
Adding a chunk-tree format creates migration and packaging cost without a
second requirement. Independent per-range reads were rejected: each would
re-verify the complete object, so reading an N-byte object in R-byte ranges
costs N * ceil(N/R) verified bytes, which for the local store's 64 MiB ceiling
and a 16 KiB range is roughly 256 GiB per saved object. Before acceptance settle
finite chunk-byte, per-read deadline, open-transfer lifetime,
concurrent-transfer and connection-work budgets alongside ADR 0023; absent
budgets block acceptance rather than imply unlimited work. Those budgets must
be stated in both Concept and Technical contracts; this proposal does not claim
them measured or accepted.

<a id="technical-adr-0028-compatibility"></a>
### Compatibility and Rollback Mechanics

Concept: [Consequences and rollback](0028-bounded-artifact-retrieval.md#concept-adr-0028-consequences).

Keep existing put/fetch callbacks and object/use formats. Add one optional
bounded transfer capability to ArtifactStore and an experimental facade
open/read/close query family. A custom ArtifactStore that does not implement
the capability returns unsupported; it does not fall back to an unbounded
fetch. Old artifacts remain readable and no format migration is introduced.
Removal restores the prior API without rewriting data.

Acceptance binds this complete pair at an exact candidate. Its evidence and
compatibility claims remain unproved until the M4 gate's required paths execute.
