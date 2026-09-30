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

Join tool calls/results by `(run_id, turn_number, tool_call_id)`, never by
turn number or provider call ID alone. Derive deterministic provider-facing
call IDs across the entire projection; retain the mapping back to canonical
identities. ADR 0044's open native thinking exchange is the explicit exception:
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
from an executor-backed tool at 2,048 encoded JSON bytes, using ADR 0042's
compact UTF-8 encoding recipe. Include normalized call ID, outcome,
excerpt and reference notice. Revision 1 projects `use_locator`, object digest,
object size, `excerpt_source: receipt_content`, excerpt byte range and explicit
omitted-content indicator. The excerpt indexes committed `result.content`,
which may include notices/diagnostics and need not equal the object bytes.
Label its source separately from the artifact object digest/size; never invent
object offsets by parsing a spill notice. Explicit range reads alone return
`excerpt_source: artifact_object` with offsets into the verified object. Retain
the existing full eight-member artifact reference durably. Select the longest
UTF-8-safe excerpt that fits after framing/reference measurement; binary content
gets a bounded description and reference, not implicit text decoding. An
unrepresentable metadata envelope produces a named staging refusal, never a
silently absent result. Model-question results preserve the exact bounded
answer/disposition from committed interaction facts. They create no executor
receipt or implicit artifact reference. They use ordinary compaction grouping
and complete request preflight; irreducible oversize refuses before dispatch.

Before producing a model-retrievable projection, require the session's frozen
read generation to support `artifact_use`. Otherwise return
`artifact_read_unavailable` before preparation writes; preserve the old tool
definitions and inline facts, with host inspection still available. No implicit
tool-set migration is permitted. Small inline results remain usable.

For new output too large for the projection, use the existing verified artifact
spill path before receipt commitment. Preserve the original terminal outcome,
receipt and diagnostics. Retention failure cannot claim a retrievable reference;
existing size/cleanup limits still apply. Full output means all bytes actually
retained by that tool under its existing limit, not unbounded process output.

For a legacy inline result without a usable reference, bounded preparation may
retain the exact UTF-8 bytes of committed `result.content`, with no added
wrapper or newline, and append `tool_result_reference_prepared`,
keyed by original receipt identity/digest and projection revision. Retain source
provenance, full reference, encoded source size and digest; this does not recover
bytes already lost by old truncation. Idempotent object/use retention converges.
Resolve an ambiguous preparation commit by its preallocated transaction ID
before staging or publication. Pure projection performs no reads or writes.
Original receipts and committed model requests remain immutable.

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

**Explicit read range.** A new generation of `read` accepts either its existing
workspace `path` inputs or `artifact_use`, nonnegative byte `offset` and positive
`length <= 1,024`; the alternatives are exclusive. `artifact_use` is the existing
`use:<sha256>` identity. The owner resolves it only from committed receipt or
prepared-reference facts of this session in the same artifact-store namespace.
Unknown, orphan, other-session and forged uses refuse. Possession is no grant;
ordinary host policy evaluates the requested use/range and the executor validates
its normal grant. Cross-session sharing is outside this branch.

After validating original model arguments, the owner adds executor-only
`resolved_artifact` to the new read generation's validated arguments. It contains `reference` as the frozen full reference and `source` with
`record_kind`, `journal_version`, `record_digest`, `run_id`, `operation_id`,
`attempt` and `tool_call_id`. All are bounded plain existing identity types. Model-supplied copies
of this member refuse. Journal the resolved job before dispatch; its existing
canonical job digest binds this member and the requested range. No top-level
executor protocol field is added. The executor validates the model-argument
projection, grant/digest, object/use consistency and provenance against the job's
session identity. The owner proves committed membership; a digest alone does
not prove journal inclusion. Recovery reuses the journaled resolution.

Use one job-owned verified transfer window per read and close it on every path.
Return actual offset, byte count, next offset and EOF, without exposing transfer
handles. Length is an upper bound: choose the largest UTF-8-safe returned range
that fits the same 2,048-byte encoded result cap after metadata. A requested
start inside a codepoint refuses; the end may shorten with explicit next offset.
Offset equal to object size returns empty EOF; offset beyond size refuses. A
binary/non-UTF-8 range gives a bounded unsupported-content result. Retrieval
results reference the original object/range and never create artifacts of
excerpts or report the source as a newly retained receipt artifact. Require
positive returned bytes unless EOF; if metadata plus one character cannot fit,
return `artifact_range_unrepresentable`. This prevents recursion and zero-progress
retrieval loops. No automatic reinjection occurs.

The M7 local profile retains referenced objects/uses with raw session history,
including after compaction and restart. It adds no automatic collection. Missing
or corrupt objects produce explicit retrieval failures; never reread a mutable
workspace path as a replacement. Whole-root backup includes these artifacts.

The final request measurement is independent: semantic messages and
`canonical_request_bytes` both retain the projection, plus receipt/envelope.
Two 16-KiB raw outputs already consume 65,536 bytes in those two representations
before framing. Neither the 2-KiB excerpt limit nor the summary-source bound
replaces full exact-record preflight.

For a known model window `W` and reply reserve `R`, the host default is `W-R`.
Reject `W <= R`. An explicit input budget cannot exceed `W-R` when known.
For an unknown window use 8,192 and label the fallback; an explicit host value
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
- Wrong-session/orphan/forged uses, denied policy, injected resolution, missing
  artifacts and digest/range corruption refuse without widening authority.
- Retention/preparation/staging fault cuts and commit_unknown fencing; cancelled
  or failed range retrieval closes its transfer and preserves receipt truth.
- Legacy inline/spilled results preserve original receipts and staged bytes;
  an old read generation refuses required retrieval without widening tools.
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
