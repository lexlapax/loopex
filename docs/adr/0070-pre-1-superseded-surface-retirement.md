<a id="concept"></a>
## Concept

Technical depth: [Retirement mechanics](0070-pre-1-superseded-surface-retirement-technical.md#technical-depth).

- **Status:** Accepted
- **Date:** 2026-10-09
- **Decision owner:** Maintainer
- **Context:** The 2026-10-02 pre-1.0 current-contract disposition and the maintainer's direction that less code is better. Several superseded surfaces survive only because accepted ADRs 0009, 0016, 0019, 0024, 0031, 0032 and 0048 name them.

<a id="concept-adr-0070-decision"></a>
### Decision

Technical depth: [Surfaces and replacements](0070-pre-1-superseded-surface-retirement-technical.md#technical-adr-0070-surfaces).

Retire these surfaces and amend only the named clauses of those ADRs:

1. **No-caller leftovers.** `Loopex.Executor.cancel/3` (ADR 0016), the one-shot
   `Loopex.Policy.decide/2` facade (ADR 0024), the bare-model
   `Loopex.LLM.ReqLLM.complete/2` refusal (ADR 0019) and
   `LoopexCli.Interrupt.install/1` (ADR 0016). Their tests move to the current
   calls.
2. **Legacy credential plane.** A host without provider bindings gets a
   one-route version-2 plane; the unversioned single-token branch is deleted
   (ADR 0048).
3. **Demo tools.** The M1 `loopex.demo.*` tools are deleted; their tests move to
   the coding tools (ADR 0009).
4. **Offline index import.** Offline CLI commands write the daemon session index
   directly, so one catalog exists; `daemon prepare-index` and the legacy import
   are deleted (ADRs 0031 and 0032).

Every other guarantee in those ADRs is unchanged.

<a id="concept-adr-0070-compatibility"></a>
### Compatibility and proof

Technical depth: [Required proof](0070-pre-1-superseded-surface-retirement-technical.md#technical-adr-0070-proof).

Before 1.0 no old caller, old root or old client is supported. A root whose
sessions exist only in the retired offline catalog is refused rather than
imported. Proof is the current suites on both supported pairs, the credential
and isolation suites, and the real-provider release lanes on the closure
candidate.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | Maintainer | [disposition](../developer/agent-context-map.md#disposition-m7-adr-0070-2026-10-09) | candidate `3aa7fedd6703c98fb468e8e7f7a1a0bfeedfa37b`; concept `sha256:6576c8ab1d8081c3ee4808ad8c950746ef7df3071391a92a4a330f6b014aa439`; technical `sha256:199ed09307ad76813cac9e98c1729a5bc81dd26fedd108e5e537fa568fdc97a4` |
