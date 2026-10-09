<a id="concept"></a>
## Concept

Technical depth: [Helper run evidence and route guard mechanics](0069-helper-run-evidence-and-route-guard-technical.md#technical-depth).

- **Status:** Accepted
- **Date:** 2026-10-09
- **Decision owner:** Maintainer
- **Context:** [ADR 0046](0046-child-session-tool.md#concept) and [ADR 0056](0056-host-helper-ledger-recipe.md#concept), only the open child-accounting access and ordinary-mutation protection prerequisites for helper execution.

<a id="concept-adr-0069-purpose"></a>
### Purpose

A helper settles a child run against the parent's delegation allowance. ADR
0046 charges reported overshoot in full, so the host needs the child run's exact
usage and the prompt's owning command digest. Core keeps only a run's total
charge and last charge source, and no host may copy Core's private accounting
rules. ADR 0056 therefore keeps helper execution closed until this access is
decided.

Helper child sessions must also stay out of reach of ordinary mutating commands
(prompt, steer, follow-up, configure, compact, answer, abort, resume), or an
operator could change a child the parent is still accounting for.

<a id="concept-adr-0069-decision"></a>
### Decision

Technical depth: [Run-evidence query](0069-helper-run-evidence-and-route-guard-technical.md#technical-adr-0069-query).

Technical depth: [Route guard](0069-helper-run-evidence-and-route-guard-technical.md#technical-adr-0069-guard).

1. **Private run-evidence query.** Runtime Control gains one read-only query,
   `Loopex.Runtime.run_evidence(runtime, session_id, run_id)`. It follows the
   `effect_intents/4` pattern: it requires the exact runtime reference, writes
   nothing and activates nothing. It returns one closed bounded map computed by
   Core's own reducer during replay: the run's admission (command identity and
   digest), its terminal state and record digest once it has ended, and its
   reported input and output, estimated and unresolved usage, including
   run-owned maintenance and excluding standalone compaction. It is never
   projected on either wire, and it adds no stored record.
2. **Host-route guard.** Every composition route (CLI, foreground app server
   and daemon) refuses ordinary mutating commands on a session classified as a
   helper child or attachment, including commands through existing
   attachments. Helpers are not exposed to runtime-only clients in M7. An
   embedder holding the raw runtime reference is trusted host code and can
   bypass the guard, as ADR 0051 already records for direct trusted hosts.

<a id="concept-adr-0069-alternatives"></a>
### Alternatives

Putting complete accounting in the public run-terminal event would change both
wire manifests and clients. Always charging the reservation would contradict
ADR 0046's overshoot rule and under-report usage. A Core session-command
admission hook, or a mutation-owner token in genesis, would add a Core port or
a persistent schema field. None is selected.

<a id="concept-adr-0069-compatibility"></a>
### Compatibility and proof

Technical depth: [Required proof](0069-helper-run-evidence-and-route-guard-technical.md#technical-adr-0069-proof).

No stored or wire format changes. The query's map is a private Core return
value. Proof requires exact query results against replayed runs with reported,
estimated, unresolved and maintenance usage, refusal for a wrong runtime or
unknown run, and route-guard refusals for every mutating command on every host
route. Acceptance authorizes implementation only.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | Maintainer | [disposition](../developer/agent-context-map.md#disposition-m7-adr-0069-2026-10-09) | candidate `31a93aa2aa26f7ac78724f21461741fa1d56b823`; concept `sha256:a810b514c38872cc7eb4d537d8435bffa92a7ba878948ea161b557aaed7abf37`; technical `sha256:c0097fa7f95121041da84c1abd9782413789dfe56a94fc848a721ceaa0f94f01` |
