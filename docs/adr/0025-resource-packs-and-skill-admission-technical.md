<a id="technical-depth"></a>
## Technical depth

Concept: [Resource packs and skill admission](0025-resource-packs-and-skill-admission.md#concept).

<a id="technical-adr-0025-decision"></a>
### Contract and Evidence

Concept: [Context and decision](0025-resource-packs-and-skill-admission.md#concept-adr-0025-decision).

### Owners and public entrypoints

The host resolver in `loopex_composition` owns roots, acquisition configuration,
frontmatter parsing, containment and installed-pack publication. It passes no
path to core. Core owns a pure `Loopex.ResourcePack` boundary:
`digest(manifest)` returns `{:ok, manifest_digest, normalized_manifest}` or a
bounded refusal; `catalog(manifest, decision)` returns `{:staged, entries,
receipt}` or `{:declined, reason, receipt}`. Catalog entries contain only
source-qualified identity, name, description, digest and manual-only status.
These pure functions are necessary for pre-session inspection; they grant no
session authority.

The public facade exposes `resource_catalog(runtime, session_id)` and
`read_resource(runtime, session_id, request)`. Session input gains
`admit_resources` and `activate_skill`, each using the existing command identity
and transaction discipline. `admit_resources` carries one bounded host decision
and manifest identity; `activate_skill` carries catalog identity and its exact
digest. Reading content returns bounded data, never a filesystem path. The
coordinator rechecks the current decision and identity before staging it.

Reference CLI: `loopex skill add <source> --rev <commit> --path <directory>` for
Git, `loopex skill add <https-SKILL.md>` for a single file, `loopex skill list`,
`loopex skill show <source-qualified-name>`, and `loopex run --skill <name>` for
explicit selection. A trust prompt displays the complete manifest digest and
source; headless hosts supply the same decision explicitly. Add never implies
trust. Default policy for import is explicit operator authorization, and every
fetch still crosses the normal executor admission path.

### Canonical manifest and limits

`manifest` has exactly `version`, `workspace_ref`, `revision`, `packs`;
version is `loopex.resource_pack/1`. Revision may be null. A pack has exactly
`source_id`, `origin`, `commit`, `tree_digest`, `name`, `description`,
`manual_only`, `files`. Origin is a bounded sanitized source descriptor with no
credential/query secret; commit is null for HTTPS and exact for Git. Each file
has exactly `label`, `size`, `digest`, `content`, `contained`; content is binary,
size and SHA-256 must match, contained must be true. Labels are relative display
strings only. The manifest digest covers normalized metadata and every file's
identity, size and digest, not just SKILL.md. Sort packs by source_id/name and
files by label. Reject duplicate identity, duplicate label or normalized-path
collision before publication/admission. An ambiguous unqualified name refuses;
there is no search-order authority.

| Bound | Ceiling |
| --- | --- |
| Catalog packs per session | 64 |
| Files per pack | 64 |
| Retained bytes per pack | 1 MiB |
| SKILL.md / one text resource | 64 KiB |
| UTF-8 label or source descriptor | 1,024 bytes |
| Skill name | Agent Skills spec's 1–64 character lowercase name grammar |
| Description | 1,024 UTF-8 bytes |
| Model-visible catalog | 16 KiB before ordinary context admission |
| Active skills per run | 4 |
| One requested supporting resource | 16 KiB, whole text or refusal |

These are candidate limits for explicit acceptance, not measurements or format
requirements imposed on the internet ecosystem. Oversized packs are diagnosed
as outside the supported subset. Total staged context still obeys the existing
run token and 65,536-byte Store-record limits; a 1 MiB retained bundle does not
mean 1 MiB of context can be admitted.

Frontmatter supports the spec's string metadata, literal/folded multiline
strings and a bounded string metadata map. Refuse aliases, tags, nested object
programming or executable interpolation. Preserve optional license and
compatibility metadata for inspection. Parse `disable-model-invocation: true`
as manual-only; executable hooks, dynamic shell markers, context-fork and
vendor-specific tool grants are unsupported diagnostics and inert content.
`allowed-tools` never changes host authority. No runtime YAML dependency is
introduced. Compatibility is the tested subset, not every vendor extension.

### Acquisition and retention

Resolve a Git reference once to an exact commit before staging and retain its
selected tree identity. Use argument vectors, explicit host Git executable,
closed configuration/environment, no submodule recursion, hooks, filters or
LFS execution. Refuse links, special files, escapes and unexpected size/counts.
Git uses the existing executor command job, not a new effect kind. HTTPS uses
an ordinary host-approved fetch in the hand: TLS validation, at most three
same-origin HTTPS redirects, a 30-second deadline and the SKILL.md byte cap.
No credentials enter source URLs, manifests or ordinary job records. Credentialed
private sources require an existing scoped host secret channel; otherwise
refuse with a clear unsupported-source diagnostic.

Stage under a task-owned sibling directory, verify every identity and bound,
then atomically rename the complete pack into host-owned content-addressed
retention. Existing content with the same digest must be byte-identical;
changed content is a new pack. Never overwrite an installed directory in place.
Interrupted acquisition retains the prior installation and cleans only owned
staging. Downloaded links never trigger additional fetches. A Git pack can
contain scripts and assets but installation invokes none of them.

### Trust, activation and admission

A decision binds workspace_ref, manifest_digest, source-qualified scope,
issued_at, decision_source and active status. M3 follows existing non-expiring
project decision semantics; removal/revocation is an explicit new admission
command, not a wall-clock guess. A catalog change invalidates the whole manifest
decision. A missing or stale decision yields a bounded declined receipt and no
skill content, while ordinary coding continues.

Selection enters the fixed context stage, never an independent injection path.
The model sees source-qualified catalog entries and can ask for an admitted
skill; the operator's explicit selection uses the same command. Each run keeps
an ordered set of at most four selected identities; duplicate selection is
idempotent, changed digest requires renewed trust, and a fifth selection
refuses rather than silently evicting another. Unselected instructions and
supporting files stay out of context. Resolve all requested content once and
stage its exact bytes/digests before provider intent commits.

Admission first resolves/measures required-only content under ADR 0017 step 5.
Then consider root AGENTS.md, the catalog, selected instruction blocks and
requested supporting blocks in that fixed order (selections in durable command
order). Each optional block is admitted whole if the resulting complete request
and receipt fit token, byte, depth and cardinality limits; otherwise withhold
that block and retain its exact closed reason. Later blocks may still fit.
Required-only failure dispatches no provider. Refusal reports the measured
required-only lower bound separately from the actual attempted cost. Historical
M2 refusal members retain their meaning and bytes.

Use versioned resource receipts with exact fixed scalar identity fields and a
bounded flat list of block dispositions; choose/check the receipt shape before
acceptance so receipt metadata cannot overflow the limit it reports. The
readiness fixtures must contain the maximal 64-pack/four-selection shape and
generated structural boundaries; schema completeness is an acceptance stop.

Recovery uses the retained staged request, not today's files or network.
Unstaged later requests may resolve the admitted immutable pack identity.
Missing retained content refuses rather than substituting new bytes. Exact
request identity does not authorize provider redispatch: ADR 0018's only
not_dispatched retry and ambiguous-attempt rules continue unchanged.

### Evidence and alternatives

Test local Git and loopback HTTPS success/refusal, atomic installation cuts,
actual staged model bytes, progressive loading, supported metadata, manual-only
selection, every admission dimension, revoked/stale identity, both hosts and
fresh-process recovery. Retain an attended public-source import separately.
Use a tiny gate-owned fixture plus a license-reviewed public example; do not
copy external code or scripts into Loopex without the ordinary reuse decision.

Deferring skills until VM-global extensions is unnecessary: their resource
contract is data-only in the code-loading sense. Building a generic context
pipeline now adds unproved plugin ownership. Treating every vendor field as
executable imports foreign authority. This fixed class is the bounded alternative.

<a id="technical-adr-0025-compatibility"></a>
### Compatibility and Rollback Mechanics

Concept: [Consequences and rollback](0025-resource-packs-and-skill-admission.md#concept-adr-0025-consequences).

Add experimental facade queries and command variants under the session owner.
New readers must replay genuine M2 histories unchanged. Old readers must refuse
unknown new records before dispatch. Restore a retained old-format root and
binary for rollback; no rewrite or in-place downgrade is promised. Existing
admitted AGENTS.md behavior and provider redispatch restrictions remain intact.

Acceptance binds this complete pair at an exact candidate. Its evidence and
compatibility claims remain unproved until the M3 gate's required paths execute.
