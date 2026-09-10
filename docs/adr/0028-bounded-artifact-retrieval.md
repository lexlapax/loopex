<a id="concept"></a>
## Concept

Technical depth: [Bounded artifact retrieval mechanics](0028-bounded-artifact-retrieval-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-09
- **Decision owner:** Maintainer
- **Prerequisite for:** M3 acceptance

<a id="concept-adr-0028-decision"></a>
### Context and Decision

M4's range-read promise requires a shared bounded implementation. Existing
ArtifactStore.fetch retrieves and validates an entire object; a small output
chunk alone does not bound memory or prove the requested object is intact.

Add bounded range retrieval through the public facade and Store boundary while
preserving ADR 0015's distinct object and use identities and closed tool_output
provenance. Validate the authorized use and stream-verify the complete immutable
object before returning a requested range. Report full-object and returned-range
digests separately. Do not label a range hash as proof of the complete object.

Technical depth: [Contract and evidence](0028-bounded-artifact-retrieval-technical.md#technical-adr-0028-decision).

<a id="concept-adr-0028-consequences"></a>
### Consequences, Compatibility and Rollback

Terminal, embedded and M4 consumers retrieve large tool output without loading
it all in memory. Full-object verification costs a sequential read per request
in this first implementation; caching and Merkle formats remain outside scope.
Resource packs do not enter the tool-output artifact namespace.

Keep existing put/fetch callbacks and object/use formats. Add one bounded
fetch_range callback and an experimental facade query. A custom Store that does
not implement the capability returns unsupported; it does not fall back to an
unbounded fetch. Old artifacts remain readable and no format migration is
introduced. Removal restores the prior API without rewriting data.

Technical depth: [Compatibility mechanics](0028-bounded-artifact-retrieval-technical.md#technical-adr-0028-compatibility).

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
