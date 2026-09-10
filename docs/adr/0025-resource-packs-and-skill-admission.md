<a id="concept"></a>
## Concept

Technical depth: [Resource packs and skill admission mechanics](0025-resource-packs-and-skill-admission-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-09
- **Decision owner:** Maintainer
- **Prerequisite for:** M3 acceptance
- **Supersedes:** 0010
- **Supersedes:** 0017

<a id="concept-adr-0025-decision"></a>
### Context and Decision

M2 admits one root AGENTS.md. Compatible skill directories add reusable operator
capability, but internet content is untrusted and multiple optional blocks
invalidate ADR 0017's single-flat-block proof. Acquisition, retention, admission
and execution need distinct owners before that capability ships.

Add one fixed resource-pack class, with Agent Skills as its first format.
Hosts acquire and parse bounded packs; core receives canonical plain data and
owns exact context admission. Preserve root AGENTS.md behavior unchanged.

Support only project `.agents/skills/<name>/SKILL.md`, with bounded supporting
files from an operator-selected Git directory at an exact commit. No HTTPS
single-file acquisition, configured/home roots or content-directed discovery.
Installation publishes an inspectable pack; session trust is a separate decision
bound to all pack bytes. Expose metadata, then operator-selected instructions
and explicitly selected manifested supporting labels. Admission and selection
require settled state before a run; the run keeps an immutable selection. Model
output is never a resource command. Scripts run only as ordinary authorized tools.

For review, this Proposed pair recommends one immutable host-supplied snapshot
per runtime, four selected skills and eight supporting files per skill. Packs
may still contain 64 files. Resource-enabled requests pay a fixed bounded
receipt-header cost before optional admission. These choices require explicit
ADR acceptance; this revision implements no runtime behavior.

One runtime serves exactly one workspace. The host retains one durable content-
addressed snapshot, while core holds one normalized immutable in-memory copy for
that runtime's life; launch validation may transiently hold both. Sessions retain
resource identities and already staged bytes, never another complete snapshot.

For project skills only, supersede ADR 0010's root-AGENTS-only permitted label,
fixed-class/cardinality, no-recursion/no-globbing and session-start-only trust
timing restrictions. The recursion exception is one bounded, content-independent
walk beneath the literal project `.agents/skills/<name>/` directory; it grants no
glob, content-directed traversal or additional discovery root. Add pre-run
resource admission while settled, not arbitrary paths or mid-run trust.
Supersede ADR 0017's zero-or-one optional-block shape proof and receipt
dispositions with versioned multi-block admission for this new class. Preserve their
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
fields are reported, not silently advertised as compatible. Activating even a
hostile pack must leave registered tools, the policy result for an identical
request and grants unchanged. Hosted remote
skills services, automatic updates, registry search, hot plugins and generic
context pipelines remain outside this decision.

Add experimental facade queries and command variants under the session owner.
New readers must replay genuine M2 histories unchanged. Old readers must refuse
unknown new records before dispatch. An M2 binary cannot open a session that
contains any `resource_command_v1`, including a session whose only resource
command was refused, or a session containing the distinct
`model_request_committed_resources_v1` record kind. Restore the matching
retained old-format root and binary for rollback; removing resource support does
not make an M3 resource-bearing root readable, and no rewrite or in-place
downgrade is promised. Existing admitted AGENTS.md behavior and provider
redispatch restrictions remain intact.

Technical depth: [Compatibility mechanics](0025-resource-packs-and-skill-admission-technical.md#technical-adr-0025-compatibility).

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
