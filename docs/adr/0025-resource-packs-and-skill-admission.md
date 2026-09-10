<a id="concept"></a>
## Concept

Technical depth: [Resource packs and skill admission mechanics](0025-resource-packs-and-skill-admission-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-09
- **Decision owner:** Maintainer
- **Prerequisite for:** M3 acceptance

<a id="concept-adr-0025-decision"></a>
### Context and Decision

M2 admits one root AGENTS.md. Compatible skill directories add reusable operator
capability, but internet content is untrusted and multiple optional blocks
invalidate ADR 0017's single-flat-block proof. Acquisition, retention, admission
and execution need distinct owners before that capability ships.

Add one fixed resource-pack class, with Agent Skills as its first format.
Hosts acquire and parse bounded packs; core receives canonical plain data and
owns exact context admission. Preserve root AGENTS.md behavior unchanged.

Support project `.agents/skills/<name>/SKILL.md` and explicit host roots; never
implicitly scan the home directory. Import an operator-selected Git directory
at an exact commit, or one explicit HTTPS SKILL.md. Installation publishes an
inspectable pack; session trust is a separate decision bound to all pack bytes.
Expose metadata first, selected instructions next and supporting content only
on explicit request. Operators can select a skill; automatic selection cannot
activate a manual-only skill. Scripts run only as ordinary authorized tools.

Narrowly supersede ADR 0010's single resource-class restriction and ADR 0017's
zero-or-one optional-block shape proof for this new class. Preserve their
required context, whole-block withholding, trust and exact staging guarantees.
Version new receipts and staging records; do not reinterpret historical bytes.
Resource bundles use host-owned content-addressed retention, not ADR 0015's
closed tool_output use schema. Context already staged for a request is durable
session data, independent of later bundle installation or removal.

Technical depth: [Contract and evidence](0025-resource-packs-and-skill-admission-technical.md#technical-adr-0025-decision).

<a id="concept-adr-0025-consequences"></a>
### Consequences, Compatibility and Rollback

An operator can reuse portable skills in the local CLI and embedding API.
M4 can consume the same catalog, selection and inspection semantics without a
second parser, trust store or activation engine. Unsupported vendor execution
fields are reported, not silently advertised as compatible. Hosted remote
skills services, automatic updates, registry search, hot plugins and generic
context pipelines remain outside this decision.

Add experimental facade queries and command variants under the session owner.
New readers must replay genuine M2 histories unchanged. Old readers must refuse
unknown new records before dispatch. Restore a retained old-format root and
binary for rollback; no rewrite or in-place downgrade is promised. Existing
admitted AGENTS.md behavior and provider redispatch restrictions remain intact.

Technical depth: [Compatibility mechanics](0025-resource-packs-and-skill-admission-technical.md#technical-adr-0025-compatibility).

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
