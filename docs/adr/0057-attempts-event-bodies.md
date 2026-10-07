<a id="concept"></a>
## Concept

Technical depth: [Attempts event bodies](0057-attempts-event-bodies-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-10-06
- **Decision owner:** Maintainer
- **Completes:** The literal event-body grammar required by [M7's attempts procedure](../plans/M7-technical.md#technical-plan-evidence).
- **Constrained by:** The accepted M7 case, ownership, handoff, causal-correction and committed-head rules, and the [current-contract disposition](../developer/agent-context-map.md#disposition-pre1-current-contract-2026-10-02).

<a id="concept-adr-0057-purpose"></a>
### Purpose and boundary

Technical depth: [Existing facts and remaining work](0057-attempts-event-bodies-technical.md#technical-adr-0057-purpose).

An attempts index retains what ran, what evidence exists, who reviewed it and
which host owns further recording. Its existing private helpers verify canonical
frames and committed heads. They deliberately accept plain body maps without
interpreting their meaning. M7 requires a closed event grammar before those
maps can become case or writer facts.

Recommend six version-1 body variants: genesis, writer designation, writer
relinquishment, writer acceptance, campaign succession and a case event. Fix
their exact members, bounded identities, evidence references and state-specific
relations. Keep the accepted six-member envelope and 65,536-byte record limit.
Genesis binds only its campaign and codec version, preserving the existing
manifest/genesis construction order.

This decision authorizes a private body codec after acceptance. Ordered replay,
exclusive writer ownership, filesystem sync, handoff recovery, evidence loading,
runner dispatch and check-command admission remain separate implementation
units required by M7. A well-formed body or frame supplies no execution authority.

<a id="concept-adr-0057-records"></a>
### Proposed records and consequences

Technical depth: [Literal schemas and relations](0057-attempts-event-bodies-technical.md#technical-adr-0057-records).

Ownership records name both writer and host, their ownership epoch, the original
handoff identity and exact preceding heads. Relinquishment references quiescence;
acceptance additionally references retained source revocation and complete
transfer evidence. The record therefore does not depend on evidence that can
exist only after that same record is appended. Succession names the lost
campaign's committed head, carried prior rows, unavailable interval and
maintainer disposition.

Every case event retains its manifest, candidate, lane, optional logical matrix,
case/subcase, fixed specification, writer and attempt identity. It records the
accepted case states and separates mechanical results from reviewed verdicts.
A next-candidate authorization retains the original failed candidate, names the
different authorized candidate and references the causal authorization. It
cannot turn a new source SHA into a permission to repeat work.

Evidence is a bounded list of references and content digests. A completed
attempt remains recorded when required evidence is missing. Its absence is
explicit, consumes the attempt and cannot establish PASS or authorize an
unchanged retry. Diagnosis and disposition are references rather than free-text
copies of logs or credentials.
Use identities up to 256 UTF-8 bytes, references up to 4,096 bytes, at most
64 evidence references, exact positive uint64 ownership epochs and current
40-character repository commit identities. References name an absolute retained
file or an exact Git revision and documentation path. The whole-record byte
limit remains the final bound.
The body codec checks syntax and local relations. Later admission verifies
referenced bytes, reviewer and maintainer authority, current ownership and
complete case history before relying on any claimed fact.

<a id="concept-adr-0057-options"></a>
### Alternatives, compatibility and proof

Technical depth: [Implementation and independent vectors](0057-attempts-event-bodies-technical.md#technical-adr-0057-options).

1. **One closed body union, recommended.** The index has one exact recipe for
   all ownership and case records. The first implementation can validate bytes
   without introducing a writer or runner. Later replay must consume that same
   recipe and still prove every M7 authority and failure rule.
2. **Separate closed recipes for each producer.** Each producer gets its own
   codec and vectors. The persisted index still needs a closed selector and
   coordinated replay across those recipes; more interfaces must change together.

Neither option permits arbitrary body maps at event admission. Before 1.0,
serve only the accepted current recipe; no older-body decoder or migration is
required. The existing framing-only helper keeps its limited purpose. No current
admitted campaign writer or event-body format is replaced by this proposal.
Existing current-format restart, uncertain append, handoff, causal review and
retained-evidence requirements remain mandatory.

Prove exact bytes and hashes, every variant, member closure, nullable relations,
integer precision and byte limits with independent vectors and negative cases
on both supported toolchains. Those checks establish codec behavior only.
They do not close any original T14 outcome or substitute for later physical
writer, recovery and dispatch proofs.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
