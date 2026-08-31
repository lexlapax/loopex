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

artifact_reference = %{
  digest: lowercase_hex_sha256,
  size: uint64,
  locator: safe_utf8_1_to_1024_bytes,
  media_type: safe_utf8_1_to_255_bytes,
  role: "tool_output",
  metadata: %{
    "session_id" => bounded_safe_identifier,
    "run_id" => bounded_safe_identifier,
    "operation_id" => bounded_safe_identifier,
    "attempt" => positive_uint64,
    "tool_call_id" => bounded_safe_identifier
  }
}
```

Core owns the only caller-facing normalization and validation facade:

```text
ArtifactStore.put(%{module:, handle:}, bytes, caller_metadata)
ArtifactStore.fetch(%{module:, handle:}, artifact_object | artifact_reference)
ArtifactStore.stat(%{module:, handle:}, locator)
```

After validation, the adapter port is:

```text
put(handle, bytes, normalized_use) -> {:ok, artifact_reference} | {:error, reason}
fetch(handle, artifact_object) -> {:ok, bytes} | {:error, reason}
stat(handle, locator) -> {:ok, artifact_object} | {:error, reason}
```

`normalized_use` is exactly `%{media_type:, role:, metadata:}` projected from
the closed shape below. The facade validates the adapter answer, requires those
three use members to equal what it supplied, and exposes no direct adapter call
to runtime, command, or embedder code. Adapters therefore receive no rejected
free-form value and cannot silently rewrite provenance while still returning a
successful reference.

Normalization is deterministic:

1. require a non-struct map with string keys;
2. remove `media_type` and `role`, applying the existing defaults only when
   absent;
3. validate those two reserved values under their existing bounds;
4. require the remaining keys to be exactly `session_id`, `run_id`,
   `operation_id`, `attempt`, and `tool_call_id`;
5. validate the four identifier values under the artifact-reference
   valid-UTF-8, no-control-or-format-codepoint, non-empty rule and an explicit
   1,024-byte field ceiling, and validate `attempt` as a positive unsigned
   64-bit integer;
6. encode exactly
   `LoopexProtocol.Canonical.encode(["artifact-use-v1", normalized_metadata])`,
   refuse that byte string above 2,048 bytes, and use those same canonical
   bytes for every adapter conformance comparison; and
7. return the same normalized map whatever insertion order the caller used.

There is no recursive arbitrary-value member. A map, list, note, credential,
float, atom, tuple, pid, reference, or function has no admitted position. The
production spill constructs this record from the already validated job rather
than accepting a second host-supplied copy of those identities.

An old five-member reference read from development state has no closed
provenance record and fails closed as unavailable. Validation and every new
durable write use the six-member form. No adapter returns or reconstructs a
five-member reference from a new `put`, and no empty metadata map is treated as
equivalent to the required five labels.

Object equality is equality of the three object members. Use equality is
equality of all six normalized reference members. An adapter may store an
internal index for pinning or collection, but it may not mutate the object or a
previous use when a later use arrives.

The core facade validates a locator before `stat(handle, locator)` reaches an
adapter and validates the returned object members. `fetch` validates and
projects the supplied object identity before adapter access, reads by locator,
computes the digest over returned bytes, and compares both digest and size. Use
metadata is ignored for byte identity but remains validated before a use
reference crosses a public or durable boundary.

<a id="technical-adr-0015-alternatives"></a>
## Alternative Costs

Concept: [Alternatives](0015-artifact-object-and-use-identity.md#concept-adr-0015-alternatives).

A composite key of bytes and metadata removes object deduplication. Mutable
sidecar metadata makes a historical receipt depend on a later call. Full
references from `stat` either invent a use or require a new query/index
contract. Passing a locator directly to `fetch` would remove the integrity facts
the caller must verify. The selected split adds one type and one nested member
while keeping each responsibility singular.

<a id="technical-adr-0015-consequences"></a>
## Compatibility, Rollback, and Evidence

Concept: [Consequences](0015-artifact-object-and-use-identity.md#concept-adr-0015-consequences).

Required closure evidence includes:

- identical bytes retained with two different caller metadata maps produce one
  object triple, two truthful use references, and byte-identical fetches;
- `stat(locator)` returns only the object triple and cannot recover or invent
  either use's metadata;
- the local adapter and test fixture run the same conformance cases;
- reserved fields normalize to the top level and every other admitted
  provenance field survives under `metadata` through put, receipt retention,
  recovery decode, public tool event, and operator retrieval;
- exact-key, missing-key, unknown-key, identifier-size, unsafe-text, attempt,
  encoded-size, and non-scalar-value negatives fail before a durable success;
- an unknown `note` member carrying the configured provider credential has no
  admitted position and fails before journal, event, artifact, diagnostic, or
  fixture retention;
- a wrong digest or size fails integrity, and an unknown locator remains
  distinguishable from an empty artifact;
- deleting metadata retention, making equality compare the whole reference as
  object identity, echoing a lookup probe, or replacing the public locator with
  the digest makes a protected case fail; and
- the adapter still publishes the object durably before returning success.

No object-file migration runs. Development references without the required
closed provenance fail unavailable rather than being upgraded with invented
labels. The prior validator also refuses the new six-member shape, so a rollback
makes histories emitted after this change unavailable; it must not rewrite them
into a false five-member history. The immutable object bytes remain readable
through the adapter's storage, but the old runtime cannot call that a recovered
receipt.
