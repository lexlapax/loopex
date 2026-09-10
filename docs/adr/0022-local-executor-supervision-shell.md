# ADR 0022 — Local executor supervision shell

<a id="concept"></a>
## Concept

Technical depth: [Supervision shell mechanics](0022-local-executor-supervision-shell-technical.md#technical-depth).

- **Status:** Accepted
- **Date:** 2026-09-07
- **Decision owner:** Maintainer

<a id="concept-supervision-shell-decision"></a>
## Decision and Scope

Require executable `/bin/bash` for the reference local executor's internal
carrier and cleanup-guard scripts. Keep model-supplied raw commands on
`/bin/sh`; argv commands still receive literal arguments without interpretation.
Core and third-party executors acquire no Bash requirement.

The carrier is the Port's direct process. The guard controls the admitted
command and its process group. A helper guard has its own group, distinct from
the carrier, so the carrier can report the guard's final exit after helper-group
termination. The decision preserves that topology and the existing authenticated
control protocol rather than redesigning either.

The maintainer explicitly approved this runtime prerequisite and directed the
repair in the [implementation disposition](../developer/agent-context-map.md#disposition-local-executor-bash-2026-09-07).
That current instruction authorizes implementation; it does not accept the
unseen bytes of this Proposed pair. Exact-pair acceptance remains separate.

Technical depth: [Mechanism and evidence](0022-local-executor-supervision-shell-technical.md#technical-supervision-shell-decision).

<a id="concept-supervision-shell-consequences"></a>
## Consequences and Alternatives

This is an explicit runtime dependency for users of `Loopex.Executor.Local`,
not an inference from Bash already being a development prerequisite. A host
without `/bin/bash` cannot use that executor's process supervision; it must
provide the prerequisite or use another executor. No silent fallback to an
incompatible shell is permitted.

The selected approach is the smallest demonstrated repair: it keeps one
supervision implementation across Darwin and Linux, with unchanged authority,
cleanup bounds, receipt meanings and public callback shapes. It requires fresh
cross-platform evidence. It adds no interpreter-selection option or framework.

Keeping only a POSIX shell would require a different, separately qualified
process-group creation mechanism. Platform-specific utilities or native code
add installation and lifecycle paths; placing helper and carrier in one group
instead changes acknowledgement and cleanup ordering. Restricting this release
to Darwin would defer the Linux defect and require an explicit coverage waiver.
None is selected. No existing gate or security requirement is weakened.

Technical depth: [Compatibility and alternatives](0022-local-executor-supervision-shell-technical.md#technical-supervision-shell-consequences).

<a id="concept-supervision-shell-rollout"></a>
## Rollout and Rollback

Document the prerequisite before offering the repaired source for review.
Prove actual commands and helpers, group ownership, private descriptor exclusion,
and truthful cleanup on the supported Darwin and Linux environments. A successful
shell-mechanism probe is not a production conformance result.

No journal or configuration migration is introduced. Reverting the repair
restores the demonstrated Linux defect and is not a qualified rollback there;
stop new Local work and select a previously qualified build or executor instead.
Do not switch a live job's interpreter or transfer its cleanup authority.

Technical depth: [Verification and rollback](0022-local-executor-supervision-shell-technical.md#technical-supervision-shell-rollout).

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | Maintainer | [disposition](../developer/agent-context-map.md#disposition-adr-0022-acceptance-2026-09-08) | candidate `4c75ae3f81f3caefe7745c40a5b24e9133255e57`; concept `sha256:d76b4996903e60a99bffcc35d31a0b0226f7123ce502b7e9a54ee7a8cd303edd`; technical `sha256:5822d3fc93548a7d3c707fb82fc1d62d1a9932d9668c8d6e28defb28fda23467` |
