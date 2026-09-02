# 0015. Artifact object and use identity — technical depth

<a id="technical-depth"></a>
## Technical depth

Concept: [Artifact object and use identity](0015-artifact-object-and-use-identity.md#concept).

<a id="technical-adr-0015-context"></a>
## The Conflated Identities

Concept: [Context](0015-artifact-object-and-use-identity.md#concept-adr-0015-context).

ADR 0009's accepted reference is exactly:

```text
%{digest:, media_type:, size:, role:, locator:}
```

and its conformance rule says a second `put` of identical bytes returns an
equal reference. The caller nevertheless supplies metadata to `put/3`, and the
executor supplies use facts such as session and tool-call identity. Those facts
cannot both survive and remain equal across distinct uses. The object/use split
preserves content addressing without erasing why a durable receipt retained the
object.

The superseded lookup probe fills four unknown values with valid placeholders.
That passes a shape validator but proves nothing about the locator. It also
forces an adapter's `stat` to decide whether to echo the caller's invented
labels or substitute one stored use. Neither answer is object truth.

<a id="technical-adr-0015-decision"></a>
## Normative Shapes and Callbacks

Concept: [Decision](0015-artifact-object-and-use-identity.md#concept-adr-0015-decision).

The plain-data shapes are:

```text
artifact_object = %{
  digest: lowercase_hex_sha256,
  size: uint64,
  locator: safe_utf8_1_to_1024_bytes
}

artifact_use = %{
  canonicalization_version: "loopex.canonical.v1",
  object_digest: lowercase_hex_sha256,
  object_size: uint64,
  object_locator: safe_utf8_1_to_1024_bytes,
  media_type: safe_utf8_1_to_255_bytes,
  role: "tool_output",
  metadata: %{
    "session_id" => nonempty_opaque_binary,
    "run_id" => nonempty_opaque_binary,
    "operation_id" => nonempty_opaque_binary,
    "attempt" => positive_integer,
    "tool_call_id" => nonempty_opaque_binary
  }
}

artifact_reference = %{
  digest: lowercase_hex_sha256,
  size: uint64,
  locator: safe_utf8_1_to_1024_bytes,
  media_type: safe_utf8_1_to_255_bytes,
  role: "tool_output",
  use_canonicalization_version: "loopex.canonical.v1",
  use_digest: lowercase_hex_sha256,
  use_locator: "use:" <> lowercase_hex_sha256
}
```

Core owns the only caller-facing normalization and validation facade:

```text
ArtifactStore.put(%{module:, handle:}, bytes, caller_metadata)
ArtifactStore.fetch(%{module:, handle:}, artifact_object | artifact_reference)
ArtifactStore.stat(%{module:, handle:}, locator)
ArtifactStore.describe(%{module:, handle:}, artifact_reference)
ArtifactStore.retrieve(%{module:, handle:}, locator)
```

After validation, the adapter port is:

```text
put(handle, bytes, normalized_use) -> {:ok, artifact_reference} | {:error, reason}
fetch(handle, artifact_object) -> {:ok, bytes} | {:error, reason}
stat(handle, locator) -> {:ok, artifact_object} | {:error, reason}
describe(handle, use_locator) -> {:ok, artifact_use} | {:error, reason}
```

`normalized_use` is exactly `%{media_type:, role:, metadata:}` projected from
the closed shape below. Core first computes the expected object digest and size
directly from the exact input bytes, then calls the adapter. It validates the
returned locator shape and requires the returned object digest and size to equal
those expected facts before that answer can reach durable or public state. Only
then can Core construct the complete `artifact_use` from the validated returned
object triple and normalized use, carrying
`canonicalization_version: LoopexProtocol.Canonical.version()`, and compute the
expected use digest from `["artifact-use-v2", artifact_use]`. The facade validates the remaining adapter answer, immediately resolves `use_locator` through
`describe/2`, and requires the described record, its recomputed digest, and the
reference's `use_canonicalization_version`, top-level media type, and role to
equal what it supplied before it returns success. An unknown or mismatched
canonicalization version is unavailable; it is never decoded with the current
encoder by assumption. The facade exposes no direct adapter call to runtime,
command, or embedder code. Adapters therefore receive no rejected free-form
value and cannot silently rewrite provenance while still returning a successful
reference. The adapter's returned `use_locator` must equal exactly
`"use:" <> use_digest`; an independently chosen safe string is invalid even
when `describe/2` can resolve it, because otherwise the public locator could
encode a private use member.

Normalization is deterministic:

1. require a non-struct map with string keys;
2. remove `media_type` and `role`, applying the existing defaults only when
   absent;
3. validate those two reserved values under their existing bounds;
4. require the remaining keys to be exactly `session_id`, `run_id`,
   `operation_id`, `attempt`, and `tool_call_id`;
5. require the four identifier values to be non-empty binaries without decoding,
   sanitizing, or rendering them, and validate `attempt` as a positive integer;
6. before allocating canonical output, sum the exact `byte_size/1` of every
   binary value plus `:erlang.external_size(attempt)`; checked addition producing
   a lower bound above 131,072 refuses `artifact_use_too_large`;
7. return the same normalized map whatever insertion order the caller used.

Step 6 is the only pre-adapter use-size refusal because the object locator does
not exist until the adapter returns the stored object identity. Its lower bound,
the locator's independent 1,024-byte ceiling, and the fixed-cardinality shape
bound the later allocation without pretending Core knows the exact locator.
After object publication, the adapter constructs the exact `artifact_use` above
with `canonicalization_version: LoopexProtocol.Canonical.version()`, encodes
exactly `LoopexProtocol.Canonical.encode(["artifact-use-v2", artifact_use])`, and
returns `artifact_use_too_large` without publishing a use or reference if those
bytes exceed 131,072. The already-published immutable object may remain an
unreferenced orphan. On success Core independently reconstructs and encodes the
same exact use from the validated returned object triple and normalized input,
checks the exact ceiling, and uses those canonical bytes for the use digest and
every adapter conformance comparison.

There is no recursive arbitrary-value member. A map, list, note, credential,
float, atom, tuple, pid, reference, or function has no admitted position. Opaque
identifier binaries may contain any bytes because their source contracts make
them identifiers rather than public text; the compact reference never publishes
them. Core binds the complete object triple, including its opaque locator, into
the use record and digest, so a use sidecar returned for one locator cannot
validate a same-bytes reference naming another. The production spill constructs
the metadata from the already validated job and committed model call rather than
accepting a second host-supplied copy of those identities or a credential. A
direct caller may supply only the closed shape; byte equality between an opaque
identifier and some unrelated secret is not interpreted as provenance. A direct
caller whose scalar lower bound already exceeds 131,072 receives
`{:error, :artifact_use_too_large}` before adapter access. A caller whose lower
bound fits but whose exact use crosses the ceiling after the object locator is
known receives the same error after object publication and no successful use or
reference.

An old five-member reference read from development state has no immutable use
record and fails closed as unavailable. Validation and every new durable write
use the eight-member form. No adapter returns or reconstructs a five-member
reference from a new `put`, and no absent use record is treated as equivalent to
the required five labels.

Object equality is equality of the three object members. Use equality is
equality of the use digest and the exact described record; two references may
therefore share an object triple while naming different immutable uses. An
adapter may store an internal index for pinning or collection, but it may not
mutate the object or a previous use when a later use arrives. It publishes the
object first and the use record second, and returns success only after both are
durable; an object orphaned by a failed use write is harmless, while a successful
reference to a missing use is forbidden. Every receipt/reference pin reaches
both the object triple and its exact use locator/digest. Collection may remove a
use only when no retained receipt/reference reaches it, and may remove object
bytes only when neither a retained reference nor any retained use reaches that
object. Losing a use sidecar while its object remains pinned is unavailable
artifact truth, not successful provenance resolution.
An object locator is permanently bound within one adapter namespace to its first
validated digest/size pair. Collection may delete unreachable object bytes but
must retain enough durable non-reuse truth—or use a deterministic
content-derived locator—to refuse assigning that locator to another object.
`stat` for a collected locator returns unavailable rather than current facts for
newer bytes. This is what makes locator-only public retrieval identifying rather
than a mutable-name lookup.
Use publication writes complete canonical bytes to an exclusive same-placement
staging object, syncs them, and atomically publishes or compares at the fixed
digest-derived locator before success. An existing byte-identical use is the
same immutable fact; an existing different, partial, unreadable, or unsynced use
is unavailable and is never overwritten. Concurrent identical puts therefore
converge without last-writer-wins mutation, and `describe/2` never observes a
successful use halfway through publication. An adapter may provide an
equivalent atomic primitive, but its conformance result must prove the same
visibility and durability boundary.

The core facade validates a locator before `stat(handle, locator)` reaches an
adapter, validates the returned object members, and requires the returned
object's locator to equal the exact requested locator. `fetch` validates and
projects the supplied object identity before adapter access, reads by locator,
computes the digest over returned bytes, and compares both digest and size. Use
metadata is ignored for byte identity. The compact reference remains validated
before a public or durable boundary, and the exact private use is revalidated
whenever an authorized caller resolves it through `describe/2`.
`retrieve(store, locator)` is the public locator-only composition: it calls the
Core `stat/2` facade, then passes only that validated exact object to the Core
`fetch/2` facade. It never constructs a probe reference and never calls an
adapter callback directly.

<a id="technical-adr-0015-alternatives"></a>
## Alternative Costs

Concept: [Alternatives](0015-artifact-object-and-use-identity.md#concept-adr-0015-alternatives).

A composite key of bytes and metadata removes object deduplication. Mutable
sidecar metadata makes a historical receipt depend on a later call; the selected
sidecar is immutable and content-digested instead. Full references from `stat`
either invent a use or require a new query/index contract, so object `stat` and
use `describe` remain separate. Passing a locator directly to `fetch` would
remove the integrity facts the caller must verify. The selected split adds one
immutable use type and one compact use locator while keeping each responsibility
singular.

<a id="technical-adr-0015-consequences"></a>
## Compatibility, Rollback, and Evidence

Concept: [Consequences](0015-artifact-object-and-use-identity.md#concept-adr-0015-consequences).

Required closure evidence includes:

- identical bytes retained with two different caller metadata maps produce one
  object triple, two truthful immutable use records and compact references, and
  byte-identical fetches;
- `put/3` computes the exact digest and size of its input and refuses a
  well-shaped adapter answer that substitutes either object fact; a mutant that
  trusts a self-consistent false reference and sidecar fails before success;
- `stat(locator)` returns only the object triple and cannot recover or invent
  either use's metadata, and a same-shaped answer naming any other locator is
  refused; `describe(reference)` projects its use locator and returns only the
  exact use whose digest the compact reference names;
- the local adapter and test fixture run the same conformance cases;
- reserved fields normalize to the top level; every exact opaque identifier,
  including invalid UTF-8 and control bytes, survives privately through put and
  `describe(reference)`, while the canonicalization-versioned bounded compact
  reference alone reaches receipt, recovery decode, public tool event, and
  operator artifact retrieval;
- exact-key, missing-key, unknown-key, empty-identifier, non-positive-attempt,
  encoded-use-size, and non-scalar-value negatives fail before a durable success;
- huge opaque-binary and positive-bignum inputs are refused by the allocation
  guard before canonical encoding, while an exact-use encoding at the ceiling
  remains admitted;
- an unknown `note` member carrying the configured provider credential has no
  admitted position and fails before journal, event, artifact, diagnostic, or
  fixture retention;
- substituting another valid object locator while keeping digest and size equal
  fails use-digest validation;
- returning a different valid locator from `stat(requested_locator)` fails even
  when digest and size are equal, and every successful compact reference uses
  exactly `"use:" <> use_digest`; a mutant admitting an adapter-selected
  safe-text use locator carrying a private provenance value fails before any
  journal, event, receipt, or operator response;
- public `retrieve(locator)` is proved to invoke validated locator-only `stat`
  followed by object `fetch`, and a mutant reconstructing the removed lookup
  probe or bypassing either Core facade fails;
- the shipped local adapter proves that its content-derived locator is a
  deterministic function of the validated object and cannot be rebound to
  different bytes. M2 ships no collection callback, so an after-collection
  rebinding mutant is not claimed as product evidence; preserving durable
  non-reuse truth becomes a reusable-adapter conformance obligation when a
  collection boundary is introduced;
- a wrong digest or size fails integrity, and an unknown locator remains
  distinguishable from an empty artifact;
- deleting use retention, making equality compare the whole reference as object
  identity, echoing a lookup probe, replacing either public locator with a
  digest, or inlining private use metadata makes a protected case fail;
- removing the object locator from the use preimage, its encoding version, or
  the allocation-safe size guard makes a protected mutation fail; and
- the adapter publishes the object and then the immutable use durably before
  returning success, and a failed use write returns no reference; and
- reopen and recovery prove every referenced use sidecar and its object remain
  available for the complete retry/recovery window because M2 collects neither.
  The combined pin/collection rule remains normative for a future collector,
  but a test-only collector is not represented as proof of shipped behavior; and
- fault injection around use staging, file sync, atomic publication, compare,
  and parent sync proves no partial use is visible and no success precedes
  durability; concurrent identical puts converge on one byte-identical use,
  while a conflicting pre-existing value fails unavailable. Mutants using a
  plain overwrite or returning before publication/sync fail by name.

No object-file migration runs. Development references without the required
closed provenance fail unavailable rather than being upgraded with invented
labels. The prior validator also refuses the new eight-member shape, so a rollback
makes histories emitted after this change unavailable; it must not rewrite them
into a false five-member history. The immutable object bytes remain readable
through the adapter's storage, but the old runtime cannot call that a recovered
receipt.
If ADR 0016's receipt-fitting path is present, rollback removes its
eight-member-reference reservation and consumer before restoring this prior
validator, or removes both in one atomic deployment. Reversing that order leaves
ADR 0016 calculating and accepting a reference shape the runtime then rejects.
