<a id="technical-depth"></a>
## Technical depth

Concept: [Session lineage projection and context budget](0041-session-lineage-projection-and-context-budget.md#concept).

<a id="technical-adr-0041-decision"></a>
### Contract

Concept: [Context and decision](0041-session-lineage-projection-and-context-budget.md#concept-adr-0041-decision).

Current source initializes each run's conversation with `[element]` in
`apps/loopex/lib/loopex/runtime/session_state.ex`; the coordinator stages that
run's elements only. Extend projection as a pure function over committed
lineage: system, admitted project context, prior runs in admission order,
current run elements and any admitted steer at its defined boundary.
The lost lineage is a current conformance defect against accepted ADR 0010;
the new projection/artifact policy is the proposed amendment, not the source
of authority to remember prior runs.

Join tool calls/results by `(run_id, turn_number, tool_call_id)`, never by
turn number or provider call ID alone. Derive deterministic provider-facing
call IDs across the entire projection; retain the mapping back to canonical
identities. Projection revision 1 uses `lx_` followed by the first 48 lowercase
hexadecimal SHA-256 characters of the canonical encoded run/turn/call identity.
Check uniqueness over the complete projected mapping; a hash collision refuses
staging rather than joining two calls. The prefix is an identifier convention,
not proof of disjointness from provider-generated IDs.
ADR 0044's open native thinking exchange is the explicit exception:
freeze its prefix mapping and preserve its original native tool IDs, rejecting
collisions before tool dispatch. After the exchange, normalize canonical history
again. Reused provider IDs in later runs must not select an earlier
result. A terminal fact may supply its committed denied/cancelled/failed/unknown
result; missing facts refuse staging rather than synthesizing success or
raising an uncontrolled owner crash.

Apply ADR 0017's estimator and exact normalized `model_request_committed`
record measurement, including context receipt, envelope and fixed-point
self-size. Preserve its depth/cardinality limits and strict system ceiling.
The 65,536-byte bound is not merely a message or canonical-request bound.
Check before provider intent/dispatch as the accepted staging rules require.
ADR 0044 adds a charged private-continuation envelope to the estimator and to
both retained request representations. Preserve its exact values; no excerpt,
artifact substitution or summary can stand in for it. Once that exchange opens,
freeze earlier result projections and context receipts; prepare new result
references only for newly appended results, without revising the frozen prefix.

**Retained output and model excerpts.** Cap each complete model-facing result
from an executor-backed tool at 2,048 encoded JSON bytes, except legacy inline
compatibility and explicitly requested artifact ranges below, using ADR 0042's
compact UTF-8 encoding recipe. Include normalized call ID, outcome,
excerpt and reference notice. Revision 1 projects `use_locator`, object digest,
object size, `excerpt_source: receipt_content`, excerpt byte range and explicit
omitted-content indicator. The excerpt indexes committed `result.content`,
which may include notices/diagnostics and need not equal the object bytes.
Label its source separately from the artifact object digest/size; never invent
object offsets by parsing a spill notice. Explicit range reads alone return
`excerpt_source: artifact_object` with offsets into the verified object. Retain
the existing full eight-member artifact reference durably. Select the longest
UTF-8-safe excerpt within both the aggregate allowance below and this result's
framing/reference measurement; binary content
gets a bounded description and reference, not implicit text decoding. An
unrepresentable metadata envelope produces a named staging refusal, never a
silently absent result. Model-question results preserve the exact bounded
answer/disposition from committed interaction facts. They create no executor
receipt or implicit artifact reference. They use complete request preflight;
irreducible oversize refuses before ordinary dispatch. Once eligible as older
history, they may enter ADR 0043's marked maintenance-source excerpt. That
exception changes neither the original answer nor its ordinary projection.

**Artifact capability identity.** The reference host registers the exact M7
`loopex.read` implementation-generation identity and tool-definition digest as
artifact-capable. The revision-1 capability table is a literal constant in core,
independent of host registries, files and runtime defaults. It contains exact
supported triples and a null-capability entry for each supported legacy triple.
Registered reference definitions must match it. The projection integration owner
pins the new `loopex.read` version and definition digest, legacy triples and byte
vectors in phase 0, before phase 1 can create an M7 session.
Capture the resolution in ADR 0044's closed `tool_selection.artifact_read`
member, not an unspecified extra genesis field. It is null, or exactly
`{revision: "loopex.artifact_read.v1", tool_id, tool_version, definition_digest}`.
The triple must name the selected `loopex.read` generation, if any, and match
the exact artifact-capable literal entry. Other IDs, including a tool merely
named `read`, gain no capability. Core derives the binding from retained exact
definitions at create and rejects an internal supplied mismatch. Public callers
cannot supply `tool_selection` or `artifact_read`. Replay uses the same immutable
literal table, without consulting the host registry. Legacy v2 selection
reconstruction uses its retained exact definitions and the same literal legacy
entries, resolving null for generations without support; it never rewrites old
genesis or upgrades an old read generation by name. An unknown `loopex.read` generation refuses that selection; other tool IDs
resolve artifact_read to null and gain no retrieval support. Do not infer capability from a
version prefix, advertised name or a guessed schema field. A legacy exact table
entry without this capability follows the inline branch below. Changing the table
requires a new generation/admitted selection, never a replay-time reinterpretation.

**Legacy inline compatibility.** For a session whose frozen read generation
does not support `artifact_use`, preserve the existing inline result shape and
the full committed `result.content`, with the normalized cross-run call identity
and original outcome. This is a compatibility exception to the 2,048-byte
excerpt cap, not permission to fetch or expand a retained artifact. It applies
to receipts produced under those frozen old definitions, including later runs
after upgrade; no timestamp or new tool-set migration determines eligibility.
Only bytes already in the receipt are available. Existing truncation or spill
notices remain explicit; this rule does not recover their omitted output or
claim that an old tool gained artifact retrieval.

Treat this inline content as fixed during ordinary aggregate allocation. Apply
all full-record, token, depth and cardinality checks, including both retained
representations. Eligible older history may compact under ADR 0043; if required
content still does not fit, refuse by the existing bound without truncating it.
Do not require a usable artifact reference merely to reuse these saved bytes,
or perform preparation writes for this compatibility projection. Producing an
artifact-retrievable excerpt still requires a supporting frozen read generation;
otherwise `artifact_read_unavailable` precedes preparation writes. Host inspection
remains available. Original receipts and previously staged requests never change.

For output from new M7 generations too large for the projection, use the existing
verified artifact spill path before receipt commitment. Measure the complete encoded projection
including its reference notice; crossing that bound triggers retention even
when output remains below the tool's capture/output ceiling. New M7
grep/find/ls generations need artifact allowances sufficient for their retained
capture ceilings; their old one-byte artifact budget cannot implement this
path. Freeze and validate those new definitions before session creation.
Do not lower capture limits merely to avoid retaining the promised source.
Preserve the original terminal outcome,
receipt and diagnostics. Retention failure cannot claim a retrievable reference;
existing size/cleanup limits still apply. Full output means all bytes actually
retained by that tool under its existing limit, not unbounded process output.

Where the frozen read generation supports artifact retrieval, bounded
preparation for a legacy inline result without a usable reference may
retain the exact UTF-8 bytes of committed `result.content`, with no added
wrapper or newline, and append `tool_result_reference_prepared`,
keyed by original receipt identity/digest and projection revision. Retain source
provenance, full reference, encoded source size and digest; this does not recover
bytes already lost by old truncation. Idempotent object/use retention converges.
Resolve an ambiguous preparation commit by its preallocated transaction ID
before staging or publication. Pure projection performs no reads or writes.
Original receipts and committed model requests remain immutable.

**Aggregate excerpt allocation.** Revision 1 uses one shared raw-prefix byte
allowance `q` in `0..2048` for eligible executor receipt-content excerpts.
Each takes the longest UTF-8-safe prefix of at most `q` raw bytes whose complete
encoded result remains at most 2,048 bytes. A shorter source saturates at its
full length. Zero emits an empty excerpt with explicit omission when source
content exists; it never omits the result or its required metadata. Binary
descriptions, user/assistant/question content, call identities/generations,
outcomes, legacy compatibility inline content, explicit artifact-range results
and frozen native prefixes are fixed.
An excerpt is eligible only with an already usable committed artifact reference.
Allocation grants no extra retention/preparation work: inline sources use the
bounded preparation episode below before they can become eligible.
These fixed-field rules govern ordinary request allocation. ADR 0043 separately
permits marked excerpts of an eligible old unit for maintenance input, including
user/assistant/question content and metadata. It preserves original facts and
never applies to an open native exchange or its protected prefix.

Before a new continuation-required exchange, ADR 0044 supplies lower byte/input
admission targets. Use them for required allocation and optional intake below,
while retaining the original hard ceilings in configuration and accounting.
Other staging uses the ordinary hard ceilings. A request within hard limits can
therefore require bounded maintenance to leave the initial thinking reserve.
The selected target never permits changing an already frozen native prefix.

Measure the required-context candidate at zero with both existing header
variants: the initial resource receipt header and the reserved longest empty
header (`retained_content_missing`). If that minimum fails, use existing eligible compaction or
named refusal; no smaller excerpt can solve it. Otherwise select the largest
`q` by bounded integer binary search, requiring both header variants to fit for
every candidate with the actual
staging serializer, fixed-point receipt, token, depth and cardinality checks.
Pin fixed-schema, monotone size/token vectors so this search cannot skip a
valid candidate. Ordinary optional-resource admission then uses the remaining
capacity under ADR 0017; allocation does not displace required facts for optional
resources. Full final preflight remains mandatory. Retain the projection
revision and resulting source ranges in the staged request/provenance. During
an open native exchange, only newly appended eligible results may vary.
This adds no call-count cap and promises no capacity for every otherwise valid
assistant group; identities, arguments and reference metadata can be irreducible.

Preparation has one episode per staging identity: oldest-first, one source per
transaction, at most 16 sources and 1,048,576 source-record bytes total, each
source at most 65,536 bytes. Commit cursor/counters, completed references and a
fixed deadline of episode start + 60,000 ms, shortened by any already active
run/caller/absolute cutoff. This separate bound applies before the relative run
deadline begins at first staging. Recovery cannot reset it or the counters.
Commit the episode identity/fixed deadline and each source identity, digest and
count/byte reservation before `ArtifactStore.put`; resolve commit_unknown before
retention. A versioned preparation-state record distinguishes reserved from
completed work. Completion commits the reference and cursor without charging
again. Recovery reuses the exact reservation, source bytes and deadline. Copy
only ADR 0015's existing five source provenance labels into use metadata; keep
preparation kind, source-record digest, projection revision and counters in the
journal, not new artifact metadata keys.
Cancellation stops preparation; exhausted count/bytes/time yields a named
refusal, never a fresh episode for the same staging identity. No provider calls
or artifact-content reads occur as preparation side effects. Already retained
references are reused and do not consume another source allowance.

Staging and preparation failures use ADR 0043's version-2 closed failure union.
Use `artifact_read_unavailable` for a required retrieval capability absent from
selection, `artifact_metadata_unrepresentable` for an individually impossible
reference envelope, and `context_projection_invalid` for missing/conflicting
canonical facts or normalized-ID collision. Preparation count, source-byte and
fixed-episode-deadline exhaustion use the corresponding `artifact_preparation_*`
cause; definite retention failure uses `artifact_preparation_failed`. Existing
run cancellation/deadline and Store commit-unknown rules take precedence. A
full numeric request overflow keeps its numeric dimension. A failure before
projection exists uses `projection_state: unavailable` and no invented counts.
This does not change executor retrieval/tool-result error schemas.

Prepare only sources in the selected ordinary projection after compaction and
tail selection; excluded old sources consume no preparation credit. Retain the
episode-start deadline and which run/caller/absolute cutoff shortened it. An
earlier ordinary cutoff produces its existing run-bound/cancellation outcome;
only the independent 60,000-ms preparation cutoff produces
`artifact_preparation_deadline`. Recovery cannot change its origin.

**Explicit read range.** A new generation of `read` accepts either its existing
workspace `path` inputs or `artifact_use`, nonnegative byte `offset` and positive
`length <= 4,096`; the alternatives are exclusive. `artifact_use` is the existing
`use:<sha256>` identity. The owner resolves it only from committed receipt or
prepared-reference facts of this session in the same artifact-store namespace.
Unknown, orphan, other-session and forged uses refuse. Possession is no grant;
ordinary host policy evaluates the requested use/range and the executor validates
its normal grant. Cross-session sharing is outside this branch.

The supported schema subset describes member types; the owner additionally
enforces both closed argument branches, exclusivity, UTF-8 and range bounds
before policy or effect intent. Unknown members, both branches, missing range
members and a supplied `resolved_artifact` produce the existing
`invalid_tool_arguments` tool-call disposition. Policy and deferred interaction
identity use only the validated original model arguments. After allow, the owner
adds executor-only
`resolved_artifact` to the new read generation's validated arguments. It contains `reference` as the frozen full reference and `source` with
`record_kind`, `journal_version`, `record_digest`, `run_id`, `operation_id`,
`attempt` and `tool_call_id`. All are bounded plain existing identity types. Model-supplied copies
of this member refuse. Journal the resolved job before dispatch; its existing
canonical job digest binds this member and the requested range. No top-level
executor protocol field is added. The executor validates the model-argument
projection, grant/digest, object/use consistency and provenance against the job's
session identity. Executor lookup selects by exact `(tool_id, tool_version)`,
then checks the digest; the first definition with that ID is insufficient. Its
argument validator enforces the same closed model branches plus the required
owner-only resolution on the artifact branch. The path branch forbids resolution.
Legacy generations keep their own validators. The owner proves committed membership; a digest alone does
not prove journal inclusion. Recovery reuses the journaled resolution.

Use one job-owned verified transfer window per read and close it on every path.
Return actual offset, byte count, next offset and EOF, without exposing transfer
handles. This explicit retrieval has an 8,192-byte complete encoded JSON result
cap, including the normalized call identity, outcome and object/range metadata.
This is the larger artifact-read result cap, separate from the legacy inline
compatibility exception. Length is
an upper bound: choose the largest UTF-8-safe returned range no longer than the
requested length that fits this larger encoded cap after metadata. A requested
start inside a codepoint refuses; the end may shorten with explicit next offset.
Offset equal to object size returns empty EOF; offset beyond size refuses. A
binary/non-UTF-8 range gives a bounded unsupported-content result. Retrieval
results reference the original object/range and never create artifacts of
excerpts or report the source as a newly retained receipt artifact. Require
positive returned bytes unless EOF; if metadata plus one character cannot fit,
return `artifact_range_unrepresentable`. This prevents recursion and zero-progress
retrieval loops. No automatic reinjection occurs.
The returned range remains exact during later ordinary projection and aggregate
allocation; never shorten it a second time to satisfy the unsolicited-excerpt
cap. Its original object reference requires no new artifact or preparation
episode. Eligible old complete groups may later compact under ADR 0043's
separate source rules. The larger result still counts in full in both retained
request representations and the input estimator. Combined reads, metadata or a
frozen thinking prefix can still exceed the complete-request ceiling; ordinary
compaction or named refusal applies, never a larger request limit.

The M7 local profile retains referenced objects/uses with raw session history,
including after compaction and restart. It adds no automatic collection. Missing
or corrupt objects produce explicit retrieval failures; never reread a mutable
workspace path as a replacement. Whole-root backup includes these artifacts.

The final request measurement is independent: semantic messages and
`canonical_request_bytes` both retain the projection, plus receipt/envelope.
Two 16-KiB raw outputs already consume 65,536 bytes in those two representations
before framing. Neither the 2-KiB excerpt limit, the 8-KiB explicit-range result
limit nor the summary-source bound
replaces full exact-record preflight.

For a known model window `W` and reply reserve `R`, the host default is `W-R`.
Reject `W <= R`. An explicit input budget cannot exceed `W-R` when known.
For an unknown window use an 8,192-token input budget and label the fallback;
do not subtract the reply reserve from that fallback again. An explicit host value
is allowed but proves no unknown model capacity. A provider/model change must
recompute and validate the effective budget. Record budget origin and value.
ADR 0043 owns automatic staging compaction and its bounded failure behavior.

<a id="technical-adr-0041-evidence"></a>
### Evidence

Concept: [Observable consequences](0041-session-lineage-projection-and-context-budget.md#concept-adr-0041-consequences).

- Two prompts and promoted follow-ups include all retained lineage with fresh
  per-run accounting; restart and owner succession project identical bytes.
- Two runs reuse turn 1 and the same tool-call ID but distinct results; no cross-join.
- Failure/cancel/unknown terminal fixtures preserve canonical facts.
- Exact record boundaries at 65,535/65,536/65,537 bytes, receipt growth and
  estimator boundaries; required staging failure versus optional withholding.
- Known/unknown model windows, invalid reserve and explicit override constraints.
- Two maximum 16-KiB tool outputs project, stage, compact and replay while
  original bytes/outcomes remain inspectable; measure actual task fixtures too.
- Encoded excerpts with quotes/control characters/multibyte text and long valid
  references; first/middle/final/empty ranges, exact next offsets, no recursion.
- Explicit lengths 4,095/4,096/4,097, encoded-result edges 8,191/8,192/8,193,
  and escaped content that must return less than the requested range. Prove
  positive progress or named refusal and unchanged requested/job/grant bounds.
  A fixture source file of at least 16 KiB requires full 4-KiB returns where
  its encoded content and metadata fit. Retain call counts, actual range sizes,
  complete staged-record/input measurements and exact next offsets through
  compaction/restart. Test combined reads and continuation prefixes separately;
  no claim that every batch or raw 4-KiB string fits follows.
- Multi-call aggregate allocation, monotone candidate sizes, optional-resource
  withholding including reserved empty-header growth, zero-prefix metadata
  overflow and unchanged frozen prefixes;
  no omitted result, extra preparation allowance or shortened explicit range read.
- Replay validates capabilities with the host registry unavailable or changed.
  Coexisting read generations resolve by ID/version. Both-branch, extra-member,
  injected-resolution and range errors fail before policy; allowed jobs alone
  carry owner resolution and bind it in their digest.
- Wrong-session/orphan/forged uses, denied policy, injected resolution, missing
  artifacts and digest/range corruption refuse without widening authority.
- Retention/preparation/staging fault cuts and commit_unknown fencing; cancelled
  or failed range retrieval closes its transfer and preserves receipt truth.
- Legacy inline/spilled results preserve original receipts and staged bytes.
  An old read generation reuses exact inline content above 2 KiB when the full
  request fits; test fit/overflow edges, later old-generation receipts, restart
  and frozen thinking prefixes. Assert no preparation write, implicit read
  capability or invented recovery of truncated/spilled bytes. Eligible compaction
  may make room; otherwise named refusal preserves the complete inline fact.
  An attempted artifact-retrievable projection still refuses without widening tools.
  Preparation count/byte/time boundaries and restart never reset allowances.
- Real multi-prompt task refers correctly to earlier diagnosis and tool evidence.

<a id="technical-adr-0041-compatibility"></a>
### Compatibility Mechanics and Alternatives

Concept: [Compatibility and rollback](0041-session-lineage-projection-and-context-budget.md#concept-adr-0041-compatibility).

Silently dropping the oldest N runs or tool-result bytes is rejected. Bounded
excerpts carry explicit references to retained bytes; compaction is an explicit
retained substitution. Version the prepared-reference record, read definition
and projection revision together; preserve old read generations for recovery. Do not claim byte identity for newly staged
legacy sessions after lineage expands; only already committed requests are
immutable. Root-reader compatibility is covered by the M7 plan's matrix.
