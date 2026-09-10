<a id="technical-depth"></a>
## Technical depth

Concept: [Bounded artifact retrieval](0028-bounded-artifact-retrieval.md#concept).

<a id="technical-adr-0028-decision"></a>
### Contract and Evidence

Concept: [Context and decision](0028-bounded-artifact-retrieval.md#concept-adr-0028-decision).

### Boundary and result

Extend the exact callback set of `Loopex.ArtifactStore` with optional
`fetch_range`; do not change `Loopex.Store` or ADR 0006 journal transactions.
This narrowly extends ADR 0015's callback inventory, leaving its object/use
schema and existing callbacks intact. Legacy ArtifactStore adapters remain
conformant and return unsupported through the facade when capability is absent.

`Loopex.read_artifact(runtime, session_id, request)` receives exactly the opaque
artifact use reference, non-negative byte offset and requested byte length.
Length is 1–16,384. Resolve authorization and ADR 0015 use identity for that
session before opening an object. The response contains the existing object and
use references, total_size, offset, bytes, object_digest and range_digest.
Offset equal to total_size returns empty bytes; offset beyond it refuses.
Length beyond the remaining object returns the remaining bytes. No path or
private tool provenance escapes through this query.

The ArtifactStore implementation opens the immutable object once, validates the use
binding, reads it sequentially with a 64 KiB buffer and a bounded accumulator
for the requested range, and verifies total size and the full SHA-256 before
releasing any bytes to the caller. Reject link replacement and changed file
identity/size around the read. Missing or corrupt object, mismatched use,
unsupported capability and invalid range have distinct bounded refusals.
Concurrent readers own separate descriptors; cancellation closes each owned
reader. The existing artifact boundary owns disk reads; core never opens paths.

### Evidence and alternatives

Test first/last/empty/overrun ranges, misuse across sessions, object-use swaps,
corruption inside and outside the requested range, concurrent readers, mutation
of range bounds, cancellation and descriptor release. Measure retained/peak
memory against objects well above the range ceiling. Genuine old-format
artifacts are positive controls. A full-object read followed by binary slicing
fails the memory obligation even when the response bytes are correct.

Returning an unchecked range with a claimed object hash overstates integrity.
Adding a chunk-tree format creates migration and packaging cost without a
second requirement. Stream verification is the smallest bounded implementation;
one request verifies at most one complete object, so reading an N-byte object
in R-byte chunks costs N * ceil(N/R) verified bytes across the complete stream.
Measure that cost with M4 frame/range sizes. Before acceptance settle finite
per-read byte/deadline, concurrent-reader and connection-work budgets alongside
ADR 0023; absent budgets block acceptance rather than imply unlimited work.
Those budgets must be stated in both Concept and Technical contracts; this
unopened proposal does not claim them measured or accepted.

<a id="technical-adr-0028-compatibility"></a>
### Compatibility and Rollback Mechanics

Concept: [Consequences and rollback](0028-bounded-artifact-retrieval.md#concept-adr-0028-consequences).

Keep existing put/fetch callbacks and object/use formats. Add one optional bounded
fetch_range ArtifactStore callback and an experimental facade query. A custom ArtifactStore that does
not implement the capability returns unsupported; it does not fall back to an
unbounded fetch. Old artifacts remain readable and no format migration is
introduced. Removal restores the prior API without rewriting data.

Acceptance binds this complete pair at an exact candidate. Its evidence and
compatibility claims remain unproved until the M4 gate's required paths execute.
