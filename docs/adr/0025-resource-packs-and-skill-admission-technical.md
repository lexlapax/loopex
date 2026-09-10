<a id="technical-depth"></a>
## Technical depth

Concept: [Resource packs and skill admission](0025-resource-packs-and-skill-admission.md#concept).

<a id="technical-adr-0025-decision"></a>
### Contract and Evidence

Concept: [Context and decision](0025-resource-packs-and-skill-admission.md#concept-adr-0025-decision).

### Owners and public entrypoints

The host resolver in `loopex_composition` owns fixed project discovery, acquisition configuration,
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
and transaction discipline. Both require a settled session before a new run;
changes during a run refuse. `admit_resources` carries one bounded host decision
and manifest identity; `activate_skill` carries catalog identity and its exact
digest plus an ordered unique `supporting_labels` list (default empty, at most
64 labels from that pack's admitted manifest). Persist labels with pre-run
selection and freeze them into the run. Unknown/wrong-pack/duplicate labels
refuse; replay of a command ID with changed labels conflicts. `read_resource`
is inspection-only and changes no selection. Reading content returns bounded
data, never a filesystem path. The
coordinator rechecks the current decision and identity before staging it.

Reference CLI: `loopex skill add <source> --rev <commit> --path <directory>` for
Git only, `loopex skill list`,
`loopex skill show <source-qualified-name>`, and `loopex run --skill <name>` for
explicit selection, with repeatable `--skill-resource <skill>:<label>` arguments
for supporting labels. A trust prompt displays the complete manifest digest and
source; headless hosts supply the same decision explicitly. Add never implies
trust. Default policy for import is explicit operator authorization, and every
fetch still crosses the normal executor admission path.

### Canonical manifest and limits

`manifest` has exactly `version`, `workspace_ref`, `revision`, `packs`;
version is `loopex.resource_pack/1`. Revision may be null. A pack has exactly
`source_id`, `origin`, `commit`, `tree_digest`, `name`, `description`,
`manual_only`, `files`. Origin is a bounded sanitized source descriptor with no
credential/query secret; commit is the exact Git source commit for imported
packs. Locally authored project packs may have null commit and must never claim
verified remote provenance. Each file
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

Require the operator's exact Git commit, verify it before staging and retain the
selected tree identity. Discovery itself only enumerates the fixed project
skill directory; it never consults workspace Git history. Importing a selected
remote Git tree is an explicit executor effect, not discovery from local history. Use argument vectors, explicit host Git executable,
closed configuration/environment, no submodule recursion, hooks, filters or
LFS execution. Refuse links, special files, escapes and unexpected size/counts.
Git uses the existing executor command job with a 30-second absolute deadline,
existing bounded output/cancellation and a probed explicit Git executable. No
new effect kind, provider-adapter HTTP client or HTTPS single-file importer is
introduced.
No credentials enter source URLs, manifests or ordinary job records. Credentialed
private sources require an existing scoped host secret channel; otherwise
refuse with a clear unsupported-source diagnostic.

Stage under a task-owned sibling directory, verify every identity and bound,
then atomically publish the complete project pack. Retain admitted pack bytes
under host-owned content identity separately from discovery and tool artifacts.
Retention configuration is not a configured resource-discovery root. Existing content with the same digest must be byte-identical;
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
The model sees catalog entries but cannot activate them. Only an explicit
operator/host command admits or selects resources while the session is settled.
Supporting requests name labels already in the admitted manifest; no model text,
link or script expands it. Each run freezes
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
Required-only failure dispatches no provider. Refusal preserves ADR 0017's existing first-failure and observed/record_byte_cost
meaning; do not invent a second lower-bound field in historical receipts. Historical
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

Test local Git success/refusal, atomic installation cuts,
actual staged model bytes, progressive loading, supported metadata, manual-only
selection, every admission dimension, revoked/stale identity, both hosts and
fresh-process recovery. Retain an attended public-source import separately.
A hostile-pack witness carries `allowed-tools: Bash(*)`, hooks and a script,
then compares canonical tool registry bytes, the host-policy result for an
identical request and the grant set before/after activation. All are unchanged,
and no executor intent arises from activation. Also refuse model-originated
selection, mid-run mutation and unknown supporting labels.
Use a tiny gate-owned fixture plus a license-reviewed public example; do not
copy external code or scripts into Loopex without the ordinary reuse decision.

Deferring skills until VM-global extensions is unnecessary: their resource
contract is data-only in the code-loading sense. Building a generic context
pipeline now adds unproved plugin ownership. Treating every vendor field as
executable imports foreign authority. This fixed class is the bounded alternative.

<a id="technical-adr-0025-compatibility"></a>
### Compatibility and Rollback Mechanics

Concept: [Consequences and rollback](0025-resource-packs-and-skill-admission.md#concept-adr-0025-consequences).

Supersession is limited to ADR 0010's root-only label/class/cardinality and
session-start-only timing for the new skills class, and ADR 0017's single
optional-block proof/receipt rules. Keep root AGENTS discovery, core's no-path
boundary, whole-manifest trust and all tool/policy/grant invariants.

Add experimental facade queries and pre-run command variants under the session owner.
New readers must replay genuine M2 histories unchanged. Old readers must refuse
unknown new records before dispatch. Restore a retained old-format root and
binary for rollback; no rewrite or in-place downgrade is promised. Existing
admitted AGENTS.md behavior and provider redispatch restrictions remain intact.

Acceptance binds this complete pair at an exact candidate. Its evidence and
compatibility claims remain unproved until the M3 gate's required paths execute.
