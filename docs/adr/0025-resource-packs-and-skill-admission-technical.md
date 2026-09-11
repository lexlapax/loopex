<a id="technical-depth"></a>
## Technical depth

Concept: [Resource packs and skill admission](0025-resource-packs-and-skill-admission.md#concept).

<a id="technical-adr-0025-decision"></a>
### Contract and Evidence

Concept: [Context and decision](0025-resource-packs-and-skill-admission.md#concept-adr-0025-decision).

All member sets, bounds and new record forms below remain **Proposed** for
maintainer review with this pair. They are not accepted persistent contracts or
authorization for dependent product implementation.

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
eight labels from that pack's admitted manifest). Persist labels with pre-run
selection and freeze them into the run. Unknown/wrong-pack/duplicate labels
refuse; replay of a command ID with changed labels conflicts. `read_resource`
is inspection-only and changes no selection. Reading content returns bounded
data, never a filesystem path. The
coordinator rechecks the current decision and identity before staging it.

Propose one optional runtime launch input, `resource_manifest: nil | manifest`.
The host supplies complete immutable canonical content, not paths or a resolver
callback. Validate counts, sizes, digests and containment assertions before
starting children. File contents total at most 64 MiB; canonical metadata with
content omitted totals at most 8 MiB. Launch data never enter genesis or a
command record. Hosts retain verified snapshots under their manifest digest
before admission, separately from installation and tool artifacts. Resume
supplies the matching snapshot, using existing prepared-resume inspection before
activation. Missing or mismatched content cannot substitute for an admitted
identity. Already staged requests remain recoverable without it. M3 proposes
no hot replacement API or automatic retained-pack garbage collection.

One runtime serves the single `workspace_ref` in that immutable snapshot. The
host owns one durable retained copy and core owns one normalized in-memory copy
for the runtime lifetime; launch validation may transiently hold both, so the
64 MiB ceiling applies to each residency. Sessions retain only resource
identities and already staged request bytes. There is no per-session snapshot
copy, second-workspace cache or runtime hot swap.

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
credential/query secret. For imported packs, `commit` is the exact Git commit
object ID and `tree_digest` is the selected directory's Git tree object ID.
Both use the repository's native object format: 40 lowercase hex characters for
SHA-1 or 64 for SHA-256, with matching formats. Locally authored project packs
have null commit and tree identity and must never claim verified remote
provenance. Each file
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
| Selected supporting files | 8 per skill; 32 per run |
| One requested supporting resource | 16 KiB, whole text or refusal |
| One complete resource command record | 16 KiB |
| Resource receipt metadata | 8 KiB; at most 37 compact block dispositions |

These are candidate limits for explicit acceptance, not measurements or format
requirements imposed on the internet ecosystem. Oversized packs are diagnosed
as outside the supported subset. Total staged context still obeys the existing
run token and 65,536-byte Store-record limits; a 1 MiB retained bundle does not
mean 1 MiB of context can be admitted.

Loopex digests are lowercase 64-character SHA-256 hex; the native Git object IDs
above are exempt from this framing. File digests use
`LoopexProtocol.Canonical.digest_bytes/1`. Manifest/pack digests use
`Canonical.digest/1` over `%{"encoding" => Canonical.version(), "kind" => kind,
"value" => normalized_metadata}`. Kinds are `loopex.resource_manifest/1` and
`loopex.resource_pack/1`; metadata has string keys and omits file content only.
Verified file sizes/digests bind the bodies. Pack/file indices are zero-based
canonical positions and always qualified by the manifest digest. Equal digest
indices do not permit unequal retained bytes.

### Proposed command and query member sets

New commands normalize atom/string aliases once into durable string-key maps;
duplicate aliases, extra keys and malformed members refuse before retention.
Command IDs are nonempty binaries of at most 256 bytes. Historical command
normalization remains unchanged.

```elixir
%{type: :admit_resources, command_id: id, manifest_digest: digest,
  decision: nil | %{manifest_digest: digest, workspace_ref: workspace,
    trust_scope: "project_skills",
    decision_source: "interactive_operator" | "host_supplied",
    issued_at: iso8601, expires_at: nil,
    revocation_state: "active" | "revoked"}}

%{type: :activate_skill, command_id: id, manifest_digest: digest,
  source_id: source, name: name, pack_digest: digest, supporting_labels: []}
```

Workspace/source labels are at most 1,024 UTF-8 bytes; issuance is a valid
ISO-8601 timestamp of at most 64 bytes. Supporting labels are ordered, unique
and at most eight per skill; `SKILL.md` is implicit. Both commands require
settled state. Canonical repetition returns its durable result before checking
current resources. Positive admission requires the configured snapshot and all
decision bindings to match. Nil/revoked decisions disable resource admission.
Disabling names the existing admitted manifest and uses its retained workspace
binding even if the launch snapshot is missing; without prior admission it
returns `resource_not_admitted`. The outer digest must match that retained
admission. A non-nil revoked decision must also match that digest, retained
workspace and `project_skills` trust scope. A mismatch returns
`resource_binding_changed` without changing resource state. Revocation never
requires rereading a pack.
New successful admission clears selections; replay does not clear them again.
Repeating an identical selection preserves order; a new command can replace
that skill's supporting labels while settled. A fifth distinct skill refuses.
Existing reply forms remain `{:accepted, command_id}` or `{:error, reason}`.

State-dependent refusals are retained and replayed. Their closed reasons are
`run_active`, `resource_manifest_missing`, `resource_binding_changed`,
`resource_not_admitted`, `resource_not_found`, `resource_selection_limit`,
`resource_support_not_found`. Malformed commands use the existing validation
error envelope and commit no partial resource state.

Propose `resource_command_v1` with exactly `kind`, `command`, `command_digest`,
`disposition`, `resolved`. The complete normalized small command uses the existing
canonical command-digest framing. Disposition is `accepted` or a reason above;
rejected records have nil resolution. Accepted admission resolves to
`workspace_ref`, `manifest_digest`. Accepted activation resolves to `pack_index`,
`instruction_file_index`, `instruction_digest`, `supporting_files`; supporting
entries have exactly `file_index`, `digest`, `size`, in requested order. Measure
the complete candidate with `Store.normalize_and_measure_item/2` and enforce
16 KiB before commit. Existing fencing and commit-unknown discipline applies.

Prompt admission freezes current resource state; follow-up promotion freezes
the then-current state. Replay reconstructs it from preceding commands without
an extra run record. `selection_digest` uses the framing above with kind
`loopex.resource_selection/1` and value containing exactly `decision` and ordered
resolved `selections`. Later requests use that frozen run snapshot.

`resource_catalog` returns exactly `configured_manifest_digest`,
`admitted_manifest_digest`, `decision_disposition`, `entries`, inside the existing
facade success envelope. Missing digests are nil. Disposition is `no_decision`,
`active`, `revoked`, `binding_changed` or `retained_content_missing`. Entries have
exactly `pack_index`, `source_id`, `name`, `description`, `pack_digest`,
`manual_only`. The complete response is bounded to 256 KiB or refuses before
return. `read_resource` accepts exactly `manifest_digest`, `source_id`, `name`,
`label`, requires active matching admission and retained content, verifies its
digest, and returns exactly `digest`, `size`, `content` in the success envelope.
Return at most 64 KiB without truncation; absent, oversized or mismatched content
refuses with `resource_manifest_missing`, `resource_not_admitted`,
`resource_binding_changed`, `resource_not_found` or `resource_byte_limit` as
applicable; a catalog response over its ceiling returns `resource_catalog_limit`.
Reading never selects. Pre-admission CLI inspection uses host data.

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
The retained provenance bundle is keyed by the canonically sorted pairs of
file label and file digest, excluding `source_id`, `origin`, `commit`,
`tree_digest` and the enclosing manifest, and stores normalized `source_id`,
sanitized `origin`, `commit`, `tree_digest` and every file digest beside the
bytes. On rediscovery or restart, the host may reattach verified remote
provenance only when that retained identity and freshly verified current pack
bytes agree; otherwise the pack is local/unverified and cannot claim remote
`commit` or `tree_digest`. Retention configuration is not a configured
resource-discovery root. Existing content with the same digest must be byte-identical;
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
Re-prove that implication with the fixed resource header plus at most 37 block
rows, 38 structural receipt elements in total: required-only failure performs no
optional resource read or optional-inclusive measurement.
Then consider root AGENTS.md, the catalog, selected instruction blocks and
requested supporting blocks in that fixed order (selections in durable command
order). Each optional block is admitted whole if the resulting complete request
and receipt fit token, byte, depth and cardinality limits; otherwise withhold
that block and retain its exact closed reason. Later blocks may still fit.
Required-only failure dispatches no provider. Refusal preserves ADR 0017's existing first-failure and observed/record_byte_cost
meaning; do not invent a second lower-bound field in historical receipts. Historical
M2 refusal members retain their meaning and bytes.

Propose `model_request_committed_resources_v1` as a distinct new journal record
kind with the existing model-record member set and versioned context receipt.
Preserve existing receipt members,
set `provider_revision` to `3`, add the `resource_pack` provenance bucket and
exactly this member (durable maps use string keys):

```text
resource_packs = {
  version: 1, manifest_digest: <64 hex>, selection_digest: <64 hex>,
  status: <closed string>, blocks: [{pack: <index>, file: <index>, status: <closed string>}, ...]
}
```

Header statuses are `not_evaluated`, `evaluated`, `no_decision`, `revoked`,
`binding_changed`, `retained_content_missing` and `metadata_budget`.
Block statuses are `not_evaluated`, `staged`, `catalog_byte_limit`,
`resource_byte_limit`, `unsupported_text`, `context_tokens`,
`context_record_depth`, `context_record_cardinality` and
`context_record_bytes`. No integer aliases or other values are admitted.
Catalog indices are `64/64`; normal indices are
`0..63`. At most 37 rows exist: catalog, four instructions, 32 supporting files.
The complete member is at most 8 KiB; violating that member-format ceiling is a
validation refusal and cannot yield `metadata_budget`. That status reports only
failure to reserve an otherwise valid member inside the complete 65,536-byte
Store record. Non-UTF-8 selected text is unsupported.

Required-only preflight includes the fixed header with status `not_evaluated`,
empty blocks.
Use the durable admitted manifest digest, including its retained identity after
revocation. Without a prior successful resource admission, retain the M2 request
form even if a launch snapshot is configured; catalog inspection reports the
missing decision without versioning an otherwise ordinary request. The
selection digest binds a nil/revoked decision and empty selections when admission
has been disabled. A header with status `no_decision` denotes that explicit nil
decision.
Its size is independent of optional contents and selection count: an explicit
new-format envelope cost that leaves M2 records unchanged. Only after success
evaluate root AGENTS, catalog, instructions, then supporting blocks. Reserve
compact disposition metadata before content. If it cannot fit, withhold the
resource class with header status `metadata_budget` and empty rows; root AGENTS retains its
existing receipt. Otherwise, each whole block must fit the complete fixed-point
record in every dimension. Later blocks may fit. Structural boundaries and the
64-pack/four-selection maximum remain mandatory implementation/closure proof.

Resource descriptors retain existing fields and
`untrusted_behavior_shaping_data` trust. Their source reference has exactly
`kind`, `manifest_digest`, `pack`, `file`, `file_digest`, with kind `resource_pack`.
For the catalog sentinel `64/64`, `file_digest` is `Canonical.digest_bytes/1`
over the exact UTF-8 model-visible catalog block. For ordinary file indices it
is the manifest's digest of the retained file bytes. Neither digest includes
its descriptor or receipt.
The request/attempt-open atomic pairing stays unchanged; no third request record
or new provider-attempt transaction is proposed. Sessions that never use resource
commands keep the existing M2 record forms.

Recovery uses the retained staged request, not today's files or network.
Unstaged later requests resolve only the run's admitted immutable snapshot.
Missing retained content declines that class with status
`retained_content_missing`, rather than
substituting new bytes or stopping ordinary coding. Exact
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

Supersession is limited to ADR 0010's root-only label/class/cardinality,
session-start-only timing and no-recursion/no-globbing rules for the new skills
class. The last exception permits only one bounded, content-independent walk
beneath the literal project `.agents/skills/<name>/` directory. ADR 0017's
single optional-block proof/receipt rules are superseded only by the fixed
header plus at most 37 rows described above; its required-only step-5 implication
is re-proved for that 38-element shape. Keep root AGENTS discovery, core's no-path
boundary, whole-manifest trust and all tool/policy/grant invariants.

Add experimental facade queries and pre-run command variants under the session owner.
New readers must replay genuine M2 histories unchanged. Old readers must refuse
unknown new records before dispatch. An M2 reader cannot open a session containing
any `resource_command_v1`, including a refused-only command, or the distinct
`model_request_committed_resources_v1` kind; this is stronger than refusing only
new writes. Rollback therefore restores the matching retained old-format root and
binary. Removing the new binary does not make a resource-bearing root readable;
no rewrite or in-place downgrade is promised. Existing admitted AGENTS.md
behavior and provider redispatch restrictions remain intact.

Acceptance binds this complete pair at an exact candidate. Its evidence and
compatibility claims remain unproved until the M3 gate's required paths execute.
