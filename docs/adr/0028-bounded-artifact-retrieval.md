<a id="concept"></a>
## Concept

Technical depth: [Bounded artifact retrieval mechanics](0028-bounded-artifact-retrieval-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-09
- **Decision owner:** Maintainer
- **Supersedes:** 0015
- **Prerequisite for:** M4 acceptance

<a id="concept-adr-0028-decision"></a>
### Context and Decision

M4's promise to save or inspect a large artifact from outside the runtime
requires a shared bounded implementation. Existing ArtifactStore.fetch
retrieves and validates an entire object; a small output chunk alone does not
bound memory or prove the requested object is intact, and verifying the whole
object again for every chunk makes saving a large object impractically slow.

Add one bounded, verified artifact transfer through the public facade and
ArtifactStore boundary while preserving ADR 0015's distinct object and use
identities and closed tool_output provenance. Narrowly extend ADR 0015's
ArtifactStore callback inventory with an optional transfer capability; the
session journal Store is unchanged. A transfer validates the authorized use,
stream-verifies the complete immutable object exactly once, then emits bounded
chunks sequentially from an owned, cancellable reader until the requested
window ends or the transfer is closed. Report the full-object digest and each
chunk's digest separately. Do not label a chunk hash as proof of the complete
object. The maintainer chose this one-verification-per-transfer design over
independent range reads on 2026-09-10 during the M4 planning task.

Technical depth: [Contract and evidence](0028-bounded-artifact-retrieval-technical.md#technical-adr-0028-decision).

<a id="concept-adr-0028-consequences"></a>
### Consequences, Compatibility and Rollback

Terminal, embedded and M4 consumers save or inspect large tool output without
loading it all in memory. Each transfer costs one complete sequential
verification plus one sequential emit of the requested window; saving an N-byte
object reads at most 2N bytes. Caching and Merkle formats remain outside scope.
Resource packs do not enter the tool-output artifact namespace. Before M4
acceptance, pair the transfer/frame contract with explicit budgets for the
opening verification (its deadline and work), chunk bytes, per-read deadline,
open-transfer lifetime, concurrent transfers and connection work. Missing
budget decisions block acceptance; they are not an unlimited-I/O grant.

Keep existing put/fetch callbacks and object/use formats. Add one optional
bounded transfer capability to ArtifactStore and an experimental facade
open/read/close query family. A custom ArtifactStore that does not implement
the capability returns unsupported; it does not fall back to an unbounded
fetch. Old artifacts remain readable and no format migration is introduced.
Removal restores the prior API without rewriting data.

Technical depth: [Compatibility mechanics](0028-bounded-artifact-retrieval-technical.md#technical-adr-0028-compatibility).

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
