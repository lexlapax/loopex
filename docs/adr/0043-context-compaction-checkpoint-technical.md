<a id="technical-depth"></a>
## Technical depth

Concept: [Bounded context compaction checkpoints](0043-context-compaction-checkpoint.md#concept).

<a id="technical-adr-0043-decision"></a>
### Contract

Concept: [Context and decision](0043-context-compaction-checkpoint.md#concept-adr-0043-decision).

**Episode.** Derive identity from the triggering run/staging identity or explicit
compact command ID. Persist frozen configuration, captured session version,
attempt count, bounds, usage and checkpoint progress. Capture its trigger as
`ordinary_limit`, `thinking_headroom`, `explicit` or `canonical_rendering`.
Also capture command origin as `automatic` or `explicit`; origin is independent
of trigger precedence. Standalone compact never captures `thinking_headroom`.
Trigger precedence is hard-limit failure, then thinking-headroom failure,
then rendering-only explicit repair, then ordinary explicit. The last rendering
case is an explicit compact command whose captured current mapping cannot
render terminal tool history; it is never an automatic rendering-only trigger.
The thinking trigger also
retains ADR 0044's rule revision and derived byte/input targets. Derive them from
the captured ordinary configuration, never the summarizer's input allowance.
Recovery validates and reuses that capture; it cannot reset the trigger or
targets. Block conflicting mutation
until settled. Steer/follow-up admission keeps its existing ordering and cannot
change the captured summary range. No live provider/executor or interaction
may overlap summary dispatch. An open ADR 0044 thinking exchange is also
ineligible: neither its current group nor any earlier rendered prefix may be
compacted or re-rendered. A staging overflow during it is the named bound
failure, not a maintenance trigger. After terminal settlement, later work can
compact canonical history without reusing the ended exchange's private data.

At most four provider attempts total per episode, including retries allowed
only after proven `not_dispatched`. ADR 0018's two-attempt limit per logical
model operation remains. An active episode consumes a model-call/turn unit for
each summary dispatch and its provider usage under the active run's bounds.
If maintenance precedes the first ordinary request, its first staged maintenance
request commits the run's absolute deadline under ADR 0013. Later maintenance
and ordinary requests reuse that instant. Every run-owned episode admission captures a fixed preparation
deadline of admission_time + 60,000 ms. Source preparation uses that deadline, shortened by any already committed
absolute cutoff; recovery cannot renew it. This narrowly extends ADR 0013's
first-request rule to a run-owned maintenance request. Every run-owned episode
captures this preparation cutoff, whether or not the run deadline is already
committed; a run cutoff at or before it wins with its existing bound outcome. A
standalone episode captures none: its own absolute cutoff governs and its expiry
is `bound_reached` with `deadline_ms`. Expiry of the fixed cutoff during the
source preparation that precedes the episode's first staged maintenance request
ends the episode and its triggering run with `context_preparation_failed`, cause
`compaction_preparation_deadline`; no run deadline instant or bound measurement
is fabricated. Preparation for later prefixes of the same episode is bounded
only by the run's committed deadline. The owner reads the
clock when it proposes the episode-admission record, for this cutoff and for a
standalone episode's absolute cutoff; command admission reads none. If that
clock value is outside the unsigned 64-bit domain or either addition overflows,
no episode is admitted and no provider call is made: a run-owned trigger ends
its run with `context_preparation_failed`, cause
`maintenance_deadline_unrepresentable`, and a standalone command commits, with
no episode record or episode terminal, its completed result
`{disposition: "failed", checkpoint_id: null, failure, usage, cleanup: "confirmed"}`
with that cause, every usage counter zero, and `context.compaction_finished`
carrying the episode identity derived from the command ID. If ADR
0013's deadline addition itself fails at that first maintenance staging, the run
ends with the existing four-key `deadline_staging_failed_v1` and
`deadline_preflight_failed` terminal pair, unchanged in shape; its validator
additionally admits the run's `maintenance` work stage, with `turn_id` still the
next ordinary turn. The episode terminal, committed first in that transaction,
records cause `maintenance_deadline_unrepresentable`.
Standalone `compact` accepts explicit `{max_attempts, deadline_ms, token_budget}`
within ceilings 4, 60,000 and 32,768 respectively. The reference `/compact` uses
4/60,000/32,768, displayed before submission; programmatic callers declare them.
All counters and the absolute deadline survive restart. Limit exhaustion prevents
another attempt; final-call token overshoot is reported, not discarded.
The public protocol exposes this as `session.compact` with an explicit closed
`bounds` object and normal command identity. It shares the M7 negotiated
contract and mutation authority with `session.configure`; a command admission
is not a completed checkpoint. Existing foreground attachment authority and
daemon controller/writer-epoch checks apply before admission.

**Selection and size.** Select ordered canonical conversation elements, excluding
maintenance records. An assistant reply plus every terminal result of its tool
calls is one indivisible group; an assistant reply with no calls is a group alone.
Each selection unit includes its preceding unconsumed user/steer elements from
the same run in original order. Contiguous unconsumed inputs left by a terminal run with no
pending operation or interaction form an input-only unit. Failed or cancelled
runs without an assistant reply must not strand those inputs. No unfinished
group is eligible. Protect current-run prompt/steer and every unfinished group.
Initially also keep the newest complete assistant group; when that group belongs
to the current run it is already protected. Measure that minimum
tail plus fixed instructions, metadata and prior checkpoint against the applicable
ordinary hard limits or ADR 0044 initial targets at `q=0`, without optional
resources. Release terminal-run units from that minimum tail oldest-first, including the
newest group and every later input-only unit, until the minimum fits and the
retained tail is rendering-eligible. Explicit command origin releases all such
terminal-run units even when the current model fits, to prepare for a smaller
model. A released unit includes its preceding inputs. Current-run inputs, every
current-run group that follows them, unfinished groups and open exchanges are
irreducible: a unit containing a current-run input is ineligible, so coverage
never passes the current run's first input. Compaction during a run can
therefore cover only history from before that run. This applies to automatic
and explicit compaction, including failed, cancelled and bound runs. Recompute
after every release; if truly protected content cannot fit, refuse by the
relevant bound. Release makes a unit eligible; it promises no arbitrary future
window.
The minimum tail is a contiguous suffix, including all later input-only units;
no earlier group can be retained while a later eligible unit is covered. Grow
the retained tail backward only while each complete group plus intervening
inputs fits both the 2,048-estimated-token preference and the applicable complete
request limits/targets. Optional tail growth cannot prevent initial preparation.
A group released by this rule cannot be re-added by optional tail growth in the
same selection. For canonical_rendering capture the last offending eligible
unit; optional tail growth stops before any offending unit. Selection, the
small-prefix rule below and this exception use strategy revision 3.

From the oldest remaining range, select the largest contiguous prefix ending
at a complete-unit boundary that fits both the 16,384-byte encoded source
envelope, including prior summary/carry-forward, and the fully rendered
maintenance request's token/record/depth/cardinality limits with its reply
reserve. Search smaller complete prefixes before refusing; the source cap alone
does not prove the maintenance request fits. A small prefix in front of a unit
that cannot join it must not strand that unit: when the selected complete prefix
has a `loopex.compaction.messages_json.v1` serialization, the `byte_length`
defined below, of at most 6,144 bytes, and the
next eligible unit exists but cannot join it within those limits, select the
prefix together with that next unit and use the marked serialized-excerpt form
below over that whole list. Coverage consumes every selected unit. This is
decided before dispatch from sizes alone, never from a failed summary. If no
quota candidate for that list fits or is valid, refuse
`compaction_excerpt_budget_too_small` before provider intent; do not fall back
to the complete prefix alone. The rule needs a next eligible unit. A small
prefix that is the whole eligible range, in front of a protected tail, is still
summarized alone and can end `compaction_no_progress`; explicit compact, which
releases the terminal tail, is the remedy. This limitation is recorded, not
hidden. If no eligible
raw range exists, make no provider call: explicit compact records idempotent
`unchanged` only if the current candidate fits and passes canonical rendering; otherwise preserve the named
staging refusal. If the irreducible protected candidate exceeds limits/targets, its numeric
refusal precedes missing maintenance settings because no summary can help it.
Otherwise, when eligible history needs maintenance, an absent model precedes
absent instructions; unsupported mapping precedes source sizing.
When an eligible range exists, explicit compact may produce
a useful bounded checkpoint even if the current model window already fits.
This permits preparation for a smaller model window. An ordinary `explicit`
trigger stops after its first committed checkpoint and reports `checkpointed`;
it never continues toward attempt exhaustion merely because more eligible
history remains. A later compact command may cover more. Begin with ADR 0041's
canonical projections: executor-backed results use artifact projections and
model-question results retain their exact bounded answer or disposition.
Compaction fetches no artifact and creates no implicit artifact reference.

If no complete prefix fits, select exactly the oldest eligible unit using the
marked serialized-excerpt form below; the small-prefix rule above selects its
short list in the same form. Coverage still consumes every selected whole unit;
the checkpoint cut never splits a tool/result group. Try per-end raw-byte
quotas 4,096, 2,048, 1,024 and 512, in that order. For each, take the
shortest UTF-8-safe prefix and suffix of at least that quota, at most three
extra bytes per end. Require a nonempty omitted middle and disjoint fragments.
Skip an invalid candidate; select the first whose exact source and complete
maintenance request pass every limit, including the 1,024-token reply reserve.
This is four local sizing candidates, not four provider attempts or a claim to
the largest possible excerpt. JSON escaping can enlarge fragments, so raw
quotas alone never establish fit. If none fits, refuse
`compaction_excerpt_budget_too_small` before provider intent. The prior checkpoint,
instructions and minimum fragments can still be irreducible in a small window.
Neither this refusal nor strict-decrease failure authorizes trimming the protected
current-run inputs, dropping prior summary data or opening another automatic episode.

**Summarizer selection.** Add immutable optional `maintenance_model` at the same
startup entrypoints as `maintenance_instructions` below. Durable and ephemeral
composition accept an exact `provider:model` string and resolve it through
ADR 0044's host capability/mapping normalizer. Validate the selected route under
ADR 0048. Direct `Loopex.start_link/1` / `Runtime.start_link/1` receive only the
closed resolved map `{model, reasoning, model_capabilities, provider_mapping}`,
with the same field bounds and combined 2-KiB capability/mapping ceiling as
ADR 0044. At startup reject a known context window at or below 1,024 or a known
output capacity below 1,024. Maintenance requires `reasoning: none`,
`provider_mapping.thinking_disabled: true` and `continuation_required: false`.
The host resolves these generic Booleans from the exact native mapping; core
does not inspect the `thinking` variant. Host registration of a summarizer
mapping also requires deterministic adapter evidence that a complete ordinary
stop produces v3 `completion: natural`; composition startup refuses a
v2/unknown-only adapter, as an unsupported mapping. Core receives no
such evidence in its closed map: for a direct embedder its guarantee is the
post-dispatch `maintenance_summary_incomplete` failure below.
The exact renderer proves its outgoing request disables thinking without raising
the committed reply ceiling; `default` and `{mode: omitted}` cannot establish
this. Other providers may encode the normalized disabled selection differently.
No credential, route handle, module, provider-option bag or live resolver enters
this map.
Core validates plain data and never consults a catalog or derives a provider
mapping from the conversation model. Composition forwards the resolved option
through runtime `Control`, durable assembly and ephemeral
`SessionOwner.runtime_options/1`.

Absent/nil means unconfigured: ordinary work is available only while its
staging limits and any initial thinking reserve fit; new maintenance refuses `maintenance_model_unconfigured`. It never means inherit the parent
model. A host may explicitly select the same model. Invalid supplied selections,
unsupported thinking-off mappings or unavailable configured routes refuse
composition startup before owned runtime/session effects; direct core startup
rejects only malformed resolved data and the window/output floors above. A
well-formed map lacking any of the three required settings starts, and each new
episode refuses `maintenance_reasoning_unsupported` before intent. Missing instructions retain their distinct
refusal. Startup and `/status` warn when a continuation-required conversation has no
maintenance model. The remedy is a host restart with an explicit admitted
summarizer; a request which needs maintenance cannot continue merely because
ordinary calls were previously possible. No public create/configure/compact or
per-prompt field overrides these host startup settings. ADR 0049 maps the model selection to explicit file/CLI
configuration; it supplies no default summarizer.

At episode admission, retain the parent configuration version and capture the
resolved maintenance selection, instruction block, effective limits and their
origins under a maintenance configuration digest. Derive the maintenance input
ceiling as the minimum of the captured parent input ceiling and the selected
summarizer's known context window minus 1,024; use the labelled 8,192-token input
fallback for an unknown window. Retain the parent's strict system-class ceiling
as a separate check, not permission to exceed the maintenance input ceiling.
Require a positive derived input allowance. A system-class overflow is the
version-2 numeric failure with the captured parent system ceiling, before intent.
Insufficient remaining run spending uses the existing run-bound outcome.
Source, complete request, depth and cardinality caps remain unchanged. This
adds no context/reply/spending knobs. Ordinary `max_tokens` governs ordinary
requests; maintenance has its own fixed 1,024-token reply allowance even when
ordinary `max_tokens` is smaller. Parent input/system ceilings and run spending
bounds still apply; the maintenance override does not rewrite them.

Recovery uses the captured model, capabilities, mapping, limits and instructions
even if current runtime options changed or are absent. Missing/corrupt capture
makes the session unavailable before scheduling; it cannot fabricate a run
terminal or use current settings to repair the capture. Dispatch-required recovery needs the
captured model's admitted provider route and renderer revision, without fallback. Missing captured routes/renderers likewise make recovery
unavailable; they do not authorize a new episode. No durable fact changes.
Restoring the captured route/renderer and restarting resumes the same episode;
a corrupt capture needs an explicitly governed repair, not current defaults.
A missing captured route or renderer does not block a known settled summary: it
needs no provider call and finishes its checkpoint, subject to the pending
progress check and the abort/deadline precedence below.
New episodes use the current runtime selection. `session.configure` changes
ordinary configuration only. Active maintenance charges the parent run's existing
calls/turns, token and deadline budgets; standalone bounds remain 4/60,000/32,768.
Report maintenance model/usage separately while counting it once in overall
usage. Maintenance in the delegating parent session spends no helper allowance.
In a child session, automatic maintenance spends that child's run bounds and is
included in its terminal usage for ADR 0046's delegation settlement exactly once;
it is not a second child admission or a separately refunded charge.

**Instructions and source encoding.** Add the optional runtime/composition
startup option `maintenance_instructions`, immutable for that runtime instance,
containing the closed `{version, body}` map below. It is host configuration,
not a new genesis member, session-create option, public `configure` field or
per-prompt override. The episode admission captures its normalized version,
rendered bytes and digest in the already-required maintenance configuration
before summary staging. Recovery uses those captured bytes even if the new
host option changed or is absent; a new episode uses the current host option.
Absence permits ordinary work and refuses new maintenance. Reference hosts
supply their shared versioned block explicitly through composition; reusable
composition and core invent none.

The entrypoints are `Loopex.start_link/1` through `Runtime.start_link/1`,
durable `LoopexComposition.start/1` and ephemeral
`LoopexComposition.Ephemeral.start_session/1`. Missing or nil is unconfigured;
per-call overrides refuse. Extend startup validation and existing closed option
lists and forward through
runtime `Control` into each coordinator, plus durable runtime assembly and
ephemeral `SessionOwner.runtime_options/1`. Two runtimes may carry different
blocks without shared state. Commit episode identity and the closed capture
`{version, rendered_bytes, digest}` before summary staging. Missing or corrupt
captured recovery data refuses; a current host value cannot repair it silently.

`version` matches ADR 0042's `[A-Za-z0-9][A-Za-z0-9._-]{0,63}`; `body` is nonempty valid UTF-8,
at most 2,048 bytes. Render
exactly `version + ": " + body`; retain those bytes and their computed SHA-256
digest in maintenance configuration. Apply the session's selected strict
system-class ceiling and complete request preflight; the body cap does not
waive either. Missing instructions refuse `maintenance_instructions_unconfigured`;
unknown fields, invalid text or section bounds refuse
`maintenance_instructions_invalid` at startup validation, before provider intent.
A maintenance refusal preserves the triggering staging identity and its named
failure. Numeric summary-request preflight uses the maintenance measurement
scope below, never invents measurements of the ordinary candidate. Core supplies no fallback, ordinary-session substitution, template
expansion or promotion of project instructions into host trust.

The reference block requests goal, constraints, progress, decisions, next steps
and critical context as sections inside the single output `summary` string.
These are prose conventions, not six machine fields or a new output union.
It also explains that serialized excerpts are incomplete data, identifies the
omitted middle, and forbids claiming unseen details, inferred file changes or
unproved outcomes. Its bounded source envelope is exactly
`{version, prior_checkpoint, messages}`, version `loopex.compaction.source.v2`.
`prior_checkpoint` is null or exactly
`{covered_range_digest, summary, carry_forward, source_excerpted}`. The digest
is the prior checkpoint's ordered covered-record integrity digest in lowercase
SHA-256 hex. The owning record retains the exact prior checkpoint identity.
Reuse its validated summary and carry-forward exactly once, without recursive
source envelopes or accumulated lists. The owner supplies the boolean
`source_excerpted`, described below. Variable-length range/checkpoint identities
remain in the owning records, not the source envelope.

The closed `messages` union has two forms:

- `{kind: "complete", value: [...]}`. The value is the nonempty ordered list of
  canonical user, assistant and tool messages in the newly consumed range,
  including tool-call generations and terminal outcomes. Steer retains its
  projected user form.
- `{kind: "serialized_excerpt", encoding: "loopex.compaction.messages_json.v1",
  sha256, byte_length, fragments: [{offset: 0, text}, {offset, text}]}`.
  Serialize that same whole message list with ADR 0042's compact sorted-key
  UTF-8 JSON recipe before excerpting it. `sha256` is its lowercase hex digest;
  `byte_length` is its byte count. Counts and offsets are unsigned 64-bit
  integers. Fragments are exact nonempty UTF-8 slices of those bytes. The second
  ends at `byte_length`; its offset exceeds the first fragment's byte length.
  The two offsets and lengths identify the omitted middle. No per-message or
  per-call headers accompany the fragments, so large group metadata is also
  excerptable. The fragments may cut JSON tokens or escapes. They are outer
  JSON strings, never parsed or repaired into native messages, calls or results.

Exclude system instructions, maintenance records and private provider data
before either encoding. The excerpt digest binds canonical projected messages;
the separate covered-record integrity digest binds complete originals. A hash
does not make an omitted detail available to the model. This grants no journal
reader or artifact capability to the summarizer.

Encode the whole envelope with the same compact recipe. Prior checkpoint data,
fragment escaping and all framing spend the 16,384-byte source cap. Stage exactly
one canonical user message whose `content` is the exact envelope JSON string.
The maintenance request contains its captured system instruction message followed
by this user message, with no tools or optional resource messages.

Extend ADR 0042's context-provider receipt revision 4 with exactly
`{kind: "compaction_source", source_digest}` and
`{kind: "compaction_summary", checkpoint_id}` source references. `source_digest`
is SHA-256 of the exact envelope JSON bytes, lowercase hex; checkpoint identity
reuses its owning record's identifier bound. The source variant is valid only for
a maintenance request whose existing episode/summary ordinal and captured range
bind that digest. The summary variant resolves the exact committed checkpoint
used by ordinary projection. At construction and replay, validate those owning
records and recompute the descriptor from the actual final message. Unknown,
missing, substituted or cross-episode references produce
`context_projection_invalid` before intent, or unavailable recovery if their
owning retained data is corrupt. Both descriptors use
`session` / `session_owned_durable_truth`: this authenticates the committed
source, not the truth of its claims or authority of its instructions.
Their six members and canonical message cost/digest recipe remain unchanged.
Retain exactly one descriptor per final message, with none for the underlying
excerpted messages. Maintenance instructions use ADR 0042's `host_instructions`
variant bound to the captured maintenance configuration. Preserve v2 replay;
preserve ADR 0025's v3 resource receipts too. These new variants require v4
validation and are not accepted under either old revision. Maintenance performs
no optional resource intake. Its `project_resource` member keeps ADR 0017's
exact four-key outer shape, `class` and `receipt_revision` unchanged, with
`disposition: "not_evaluated_maintenance"` and `detail: null`. If an admitted
manifest requires ADR 0025's fixed resource header, retain it with
`not_evaluated` and empty block rows. These successful-request dispositions are
permitted only for revision-4 maintenance; ordinary requests and v2/v3 replay
keep their prior rules. Bind header manifest/selection digests to resource
admission state captured with the episode's session version. Require no project
or resource-pack descriptors and zero costs in their applicable provenance
buckets. Charge all header metadata in full record preflight. No current host
resource reread may replace those captured identities on recovery.
Use the actual
serializer, fixed-point receipt and token/depth/cardinality checks for the entire
65,536-byte request, including semantic fields and canonical bytes. Stream source
counting/hashing and projection over the captured range, with bounded source
pages/records and two end buffers of at most 4,099 bytes each. Do not collect an
unbounded projected message list or serialized unit. Complete-prefix sizing
retains at most the 16,384-byte candidate. Check cancellation/deadline between
bounded reads and encoding chunks; traversal spends the episode deadline.
Staging retains the exact selected source in the existing request;
episode/checkpoint metadata bind its digest and strategy revision without a new
duplicate source payload. Recovery reuses those staged bytes, never reselects
against current host settings or a different projection.

Maintenance has no tools and reserves 1,024 reply tokens. Its captured separate
configuration uses the exact selected summarizer and verified thinking-off
mapping described above. Display this purpose-specific configuration; it does
not change ordinary run configuration.
Require capability evidence for that setting before dispatch, otherwise refuse
`maintenance_reasoning_unsupported`. Do not let a manual thinking budget or
dependency translation enlarge the 1,024-token reply reserve. Maintenance
starts with nil continuation and never consumes or creates a reusable ordinary
exchange. Private thinking is excluded from summary input and checkpoint data.
Full token/record/depth/cardinality preflight still applies.
Reject a model incapable of that reserve or insufficient remaining budget before
dispatch. A summary reply must have no tool calls; otherwise fail maintenance_summary_invalid
without policy/executor dispatch, charging its validated usage. Output is closed
JSON with `summary` at most 4,096 bytes after canonical JSON
string encoding, including quotes and escaping, and `carry_forward` containing
arrays `files_read` and `files_changed`, together at most 2,048 encoded bytes.
The whole encoded summary/carry-forward envelope is at most 6,144 bytes, so
independently maximal members may need to be smaller to leave room for framing. Bound each path to 1,024 bytes and each list to 32
entries. Unknown/invalid/oversize output fails without a hidden repair call. The 6,144-byte
limit is an admission ceiling, not output capacity promised by 1,024 tokens.
The reference instruction asks for a compact envelope below 3,072 encoded bytes.
ADR 0044's v3 reply carries the adapter-validated `completion` classification;
maintenance requires that version and `completion: natural`. A native
`max_tokens` stop, its normalized `length` equivalent (`completion: limit`),
or unknown completion, even with parseable JSON, fails as
`maintenance_summary_incomplete`; malformed, extra-key or oversized output fails
as `maintenance_summary_invalid`. Completion is checked first: a readable reply
whose completion is not `natural` fails `maintenance_summary_incomplete`
whatever its tool calls or content; only a `natural` reply can fail
`maintenance_summary_invalid`. An adapter reply that core cannot read at all,
including ADR 0044's eight-key case, keeps ADR 0018's unreadable-answer result
and accounting inside the maintenance settlement kind and, for a run-owned
episode, its run terminal
(`unreadable_model_answer`); a standalone episode has no run terminal. The episode's closed
failure union has no such member and records it as `model_call_failed`. A
well-formed nine-key v2 reply is readable: it carries `completion: unknown` and
fails `maintenance_summary_incomplete`. Both summary failures consume the attempt and observed or
conservative usage under the existing accounting rules; neither permits a repair
call or a fresh automatic episode.

Evaluate the pending substitution in memory against the captured projection
before checkpoint commit, using the same serializer and estimator. For a
thinking-headroom trigger, compare the minimum required projection at `q=0`,
without optional resources. For `ordinary_limit`, `thinking_headroom` and
ordinary `explicit`, require strict decrease in both exact record bytes and
estimated tokens. A checkpoint may remain above the captured targets while
making that strict progress; the bounded episode then consumes another prefix.
For `canonical_rendering`, require an advancing contiguous raw cut toward the
captured last offending unit and a resulting candidate within every ordinary
hard limit; byte/token growth is allowed. Continue for rendering only under
that trigger, consuming new raw units until rendering passes. No repeated cut
or summary-only cycle is allowed.
Any failed progress test, including an over-limit rendering substitution, ends
with `compaction_no_progress`. Retain the summary only as settlement evidence;
do not commit a checkpoint or publish `context.compacted`. Recovery performs
this same check on `checkpoint_pending` before it may finish a checkpoint.
For size/headroom triggers, stop once the applicable limits/targets fit;
ordinary `explicit` stops after its first committed checkpoint. If
canonical rendering then remains unsupported, preserve
`canonical_history_rendering_unsupported`; do not make another paid call to
repair rendering automatically. If a parent bound, cancellation, deadline,
provider failure or unresolved commit already wins under the existing precedence,
retain that outcome. Otherwise, exhaustion of a run-owned episode's independent
four-attempt ceiling retains partial checkpoints and the current measured
staging/headroom failure in both the episode and triggering run. Its attempt
count remains episode evidence, not a new parent max_attempts bound. Standalone
exhaustion uses its captured max_attempts bound below. A specific maintenance
failure takes precedence. No fresh automatic episode for that staging identity
is permitted. Once targets fit, ordinary excerpt/optional admission uses the
remaining capacity below those targets, with exact final preflight. All maintenance requests keep their own existing hard limits;
the ordinary pre-exchange targets do not halve the summarizer's allowance.

**Refusal records and projections.** This proposal amends ADR 0017's closed
failure and refusal unions. Old `context_admission_refused_v1` and its five-key
failure retain their exact rules, including the 1,000 system limit. New staging
uses `context_admission_refused_v2`; never replay old bytes as the new revision.
Its exact members are ADR 0017's nineteen-key v1 shape with `kind` changed to
v2, the four members `category`, `dimension`, `observed`, `limit` replaced by
`failure`, and five added members: `configuration_version`, `episode_id`,
`targets`, `projection_state` and `measurement_scope`. Configuration is the
captured version; episode is null or its bounded owning identity. Historical
required-only count/digest/disposition rules remain for the canonical descriptor
sequence. The complete estimate additionally includes continuation under ADR
0044; it is not asserted equal to descriptor subtotals alone. Use ADR 0044's
estimator for new requests, including continuation cost. `targets` is null for
ordinary hard-limit refusal, or exactly `{revision, record_target, input_target}`
with ADR 0044's captured rule and recomputed values. No source text is retained. `projection_state` is `measured` or `unavailable`.
Numeric failures require measured. With measured, measurement_scope is exactly
`ordinary` or `maintenance`; counts/digest/estimate describe that captured
minimum candidate, not an admitted request. Frozen project/resource descriptors
remain part of that candidate when ADR 0044 forbids changing the earlier prefix.
The maintainer selected the following count amendment on 2026-10-02:

- The exact historical four-count v2 shape remains valid for required-only input.
- A measured candidate containing frozen optional descriptors adds exactly the pair
  `project_resource_count` and `resource_pack_count`. Both are unsigned 64-bit
  integers, including truthful zero for an absent class. At least one is
  positive; the six counts are individually bounded and their sum cannot exceed
  unsigned 64-bit range. In the live constructor their sum equals the complete
  descriptor count. Tool definitions are counted separately from messages even
  when their descriptor provenance is system.
  Fresh optional intake retains its earlier whole-block admission/withholding
  path; this extension cannot turn a removable optional block into a terminal
  required-context failure.
- Project descriptors have provenance `project_resource`; resource descriptors
  have provenance `resource_pack`. The pair partitions those exact message
  descriptors, preserving the ordered descriptor digest and full provider token
  estimate. A positive project count requires project disposition `staged`, and
  `staged` requires a positive project count. Resource-only candidates retain
  the applicable earlier project disposition. Required-only shapes do not gain
  a staged nonempty project claim.
- Missing one member, extra members, negative, noninteger or overflowing counts,
  an all-zero added pair, or inconsistent project disposition refuse. Recovery
  preserves committed observations and validates their shape, bounds and
  relations; it does not fabricate a rejected descriptor preimage. Earlier
  readers must refuse the extended shape rather than stripping its counts.
- Unavailable projections retain their exact historical shape with four null
  counts; they omit the added pair because no optional projection was measured.
  The amendment adds no source bodies or new public failure members. Prove the
  live partition and ordered digest against the actual preflight input, and
  compare the complete normalized refusal's measured bytes with independent
  deterministic external-term encoding. Keep required-only v1/v2 replay proofs.

Ordinary uses the last minimum
projection; maintenance requires its owning episode and captured summary request
configuration, with targets null and the episode's derived input allowance.
Its system limit remains the captured parent system ceiling. A measured
nonnumeric preparation failure uses `ordinary` scope; nonnumeric failures have
no maintenance-budget observation. Measured record
cost may still be null under the earlier preflight-order rules. With unavailable,
permitted only for a nonnumeric failure before projection exists, measurement_scope
is null and
the four counts, ordered descriptor digest, provider estimate and record cost
are all null, never fabricated zero observations. Its `project_disposition` is
`not_evaluated_required_failure`; a missing projection cannot claim resource
admission or maintenance evaluation. Captured configuration/budgets
and any derived targets remain required. For nonnumeric preparation failure,
record cost is null. Standalone compact
uses its episode record instead, or its completed command result alone when no
episode was admitted, and emits no invented context-refusal run record.

The new `failure` is one of these exact closed objects:

- `{version: 2, category: "context_budget_exceeded" | "thinking_exchange_headroom",
  retryable: false, measurement_scope, dimension, observed, limit, hard_limit}`.
  Scope is exactly `ordinary` or `maintenance`, matching the measured candidate
  in the owning refusal or episode; it remains present in public failure views. The dimension is
  one of ADR 0017's five values. Private observed/limit/hard_limit are unsigned 64-bit integers; limit/hard_limit
  are positive. New public wire/pipe projections encode these values as canonical
  decimal strings, without changing private measurement relations. Ordinary token, byte and structural limits retain ADR 0017's
  measurement relations, with `hard_limit == limit`; system limit instead equals
  the captured configured `system_class_tokens` and refuses at `observed >= limit`.
  Other dimensions refuse only above the limit. Headroom permits only
  `context_tokens` or `context_record_bytes`: limit equals the corresponding
  captured target, hard_limit equals the captured ordinary input ceiling or
  65,536, and `observed > limit` even when observed does not exceed hard_limit.
  Record cost equals observed only for the byte dimension, as before.
- `{version: 2, category: "context_preparation_failed", retryable: false,
  measurement_scope, cause}`. Scope is `ordinary` when a required projection
  was measured, otherwise null. No numeric observation is implied.
  The closed causes are `maintenance_model_unconfigured`,
  `maintenance_instructions_unconfigured`, `maintenance_reasoning_unsupported`,
  `compaction_excerpt_budget_too_small`, `compaction_no_progress`,
  `compaction_preparation_deadline`, `maintenance_deadline_unrepresentable`,
  `maintenance_summary_incomplete`, `maintenance_summary_invalid`, and
  `canonical_history_rendering_unsupported`, `artifact_read_unavailable`,
  `artifact_metadata_unrepresentable`, `artifact_preparation_count_exhausted`,
  `artifact_preparation_bytes_exhausted`, `artifact_preparation_deadline`,
  `artifact_preparation_failed`, and `context_projection_invalid`. They report a condition, not a
  fabricated numeric budget observation. Invalid startup configuration has no
  run record and remains a startup validation error.

For an active ordinary run with an admitted episode, commit in this order in
one transaction: episode terminal, v2 refusal, failed `run_terminal_committed`.
The refusal immediately precedes the run terminal, with no intervening record.
Without an episode, commit only the latter two. A run-owned episode ended by
cancellation, a parent bound, provider failure or deadline-staging failure
commits its episode terminal as the first row of the transaction that contains
the existing run terminal. Every consecutive pair, a settlement then terminal
(the maintenance settlement kind when the ending call is a summary call, ADR
0018's otherwise) and ADR 0017's `deadline_staging_failed_v1` then terminal,
stays adjacent. This amends the "contains exactly"
cardinality of those ADR 0017 and ADR 0018 transactions by one leading row, for
a run-owned episode only. An episode terminal committed as the leading row of
any run-terminal transaction, including the refusal transaction above, installs a transient
episode-pending-terminal marker and applies no effect; its failure and usage are
validated and applied together with the run terminal that completes the same
transaction. Reaching the durable head, or any row outside that transaction,
with the marker pending is invalid history.
Permit refusal v2 at the
`maintenance` stage, bound to that episode; its closed substates are
`source_preparation`, `model_pending`, `checkpoint_pending` and `settling`. Preserve the no-second-settlement rule, substituting only the nested failure
union in ADR 0017's exact terminal shape. Bind its configuration, staging identity,
measurements and optional episode to the owning records. Maintain cancellation,
deadline, provider failure and commit-unknown precedence; those existing outcomes
keep their own schemas and do not become preparation failures. A completed
maintenance failure records its cause in the episode terminal and ends the
triggering run with that same projection, without a second provider settlement;
the deadline-staging case above keeps the run's own terminal instead.
Standalone compact measures current canonical history plus captured fixed
configuration under current hard limits/rendering rules; it invents no prompt
or run-staging identity. Run-owned and standalone episode terminals share the same closed five-member
container, with the owner-specific bound branches below. The standalone
idempotent completed-command result is exactly `{disposition, checkpoint_id, failure, usage, cleanup}`.
Dispositions are `checkpointed`, `unchanged` and `failed`. Checkpoint_id is the
latest checkpoint produced by this episode or null; checkpointed requires one,
unchanged requires null, and failed may retain a partial checkpoint. Cleanup is
`confirmed` or `unknown`; success requires confirmed. Failure is null iff
successful, otherwise exactly one of:

- the version-2 context failure union above;
- `{category: "model_call_failed", retryable: false}`;
- `{category: "cancelled", retryable: false}`;
- `{category: "bound_reached", retryable: false, bound, observed,
  declared_limit, accounting_source}`. For a run-owned episode, parent-bound
  exhaustion uses `max_turns`, `deadline_ms` or `token_budget` and copies the
  owning run's exact bound measurements and accounting source under ADRs
  0011/0013/0017/0018. The episode's `deadline_ms` bound value corresponds to the
  run terminal's existing `deadline` bound literal and copies its observed and
  declared values unchanged; the run terminal keeps its own literal. It does not replace turn exhaustion with the episode's
  attempt ceiling. A run-owned episode rejects `max_attempts` in this branch;
  its independent attempt exhaustion uses the context failure specified above.
  Standalone compact admits only `max_attempts`, `deadline_ms` and `token_budget`;
  `max_turns` refuses. Attempts and tokens use their captured positive ceilings;
  a standalone deadline's declared_limit is the captured absolute cutoff and
  observed the clock observation, never the duration. Accounting_source is null, reported
  or estimated, consistent with the episode's retained usage; max_attempts uses
  null. All observations are nonnegative integers. Public numbers use exact
  decimal strings.

These branches retain normal provider/cancellation/spending precedence and
measurements without a synthetic run identity. Usage is exactly `{attempts, reported_tokens, estimated_tokens, total_tokens}`.
Attempts is the episode attempt counter within its captured ceiling. Token
counters are nonnegative integers summing validated reported charges and the
existing conservative estimated charges once; total equals reported plus
estimated. Public counters use exact decimal strings. This summarizes retained
accounting, without creating reported usage from an invalid reply. A failed result is never a
successful checkpoint completion merely because a partial checkpoint exists.
Admission acknowledgement is distinct from completion. `session.abort` also
cancels active standalone maintenance through its episode identity and normal
bounded cleanup; it creates no run or run-terminal record. This explicitly
amends ADR 0011's abort handling under the new generations. While standalone
maintenance is active, duplicate command IDs are checked first. Fresh prompt,
steer, follow-up, configure, compact and interaction-response commands commit
idempotent refusal `maintenance_active`; they cannot queue or change the episode.
A compact command received while a run is active commits ADR 0011's existing
`run_active` refusal, unchanged.
Abort returns its normal admitted acknowledgement bound to the episode, then
completion reports cancellation/cleanup; it has no run ID. Read-only attachment,
inspection and status remain available. Run-owned maintenance keeps ordinary
run input ordering and its captured-range protection. No run/refusal
record is invented. `unchanged` is successful
only under the selection rule above. Standalone exhausted attempts/usage/deadline
retain the bound outcome above and its measurements; a run-owned episode follows
its owner-specific branches. An episode's before/after projection
measurements prove no-progress locally; they are not new public payload fields.

Standalone completion publishes the new `context.compaction_finished` event
with exactly `{episode_id, command_id, result}`, where result is the closed
five-member object above, for checkpointed, unchanged and failed alike. The new
session snapshot has `last_compact`, null or that same completed payload;
reattachment therefore discovers completion even when no checkpoint was made.
The event is committed with the command result, and with the episode terminal
when an episode was admitted, before publication, never inferred from progress. Run-owned episode identity stays in
its owning record and existing run outcome.

`run.finished`, compact completion and snapshot failure views carry this exact
version-2 object under the new foreground/daemon generations. CLI rendering uses
only these safe fields. Version-1 and version-2 validators, reducer transactions,
snapshot/event projections and independent Node vectors must reject unknown
keys/causes, wrong configured limits, fabricated targets and cross-version shapes.
The compact private refusal itself must pass Store bounds before proposing its
transaction; failure to retain it means Store unavailable, never a fabricated
terminal or acknowledgement. Detailed provider blocks and descriptors remain
absent from all failure projections.

**Checkpoint.** Retain original lineage/range, newly consumed raw range, prior
checkpoint ID if any, first-kept identity, summary/carry-forward bytes, strategy
`loopex.compaction.reference` revision 3, exact model/reasoning/configuration
version, usage, summary-input digest and ordered covered-record integrity digest.
Ranges extend contiguously without gaps/cycles and never split tool/result groups.
Retain the owner-computed boolean `source_excerpted`: the prior checkpoint's
value, or false when absent, OR this source's `serialized_excerpt` kind. It is
not a model-output field. Later complete-source summaries cannot erase an earlier
omission. Include it in checkpoint inspection, `context.compacted`, the public
checkpoint snapshot and the rendered summary provenance.
This flag tracks additional maintenance excerpting. A false value promises
neither full artifact contents in ordinary projections nor a lossless summary.
Projection renders one canonical user message containing compact JSON with
exactly `{kind: "compaction_summary", checkpoint_id, covered_range_digest,
summary, carry_forward, source_excerpted}`, using the same JSON recipe. It is
untrusted conversation data and never a system instruction or synthetic tool
result. Adapter vectors fix this rendering and its revision-4 descriptor. It is followed by
every later canonical element from the first-kept identity in original order,
including any unsummarized middle and the protected tail. No summary text becomes authority or a fabricated raw fact.

**Commit and recovery.** Derive a distinct maintenance operation ID from episode
ID and summary ordinal; allowed retries retain that ID and cannot collide with
ordinary run/turn identities. Reuse ADR 0018 permits, dispatch classification and
accounting with explicit `compaction` purpose. Maintenance request, attempt and
settlement records are new kinds that carry `episode_id` and summary ordinal in
place of `run_id`/`turn_id`, plus that purpose; a run-owned episode additionally
binds its run through the episode record. ADR 0018's existing kinds are not
written for maintenance. The maintenance settlement carries ADR 0044's v3 reply,
result and accounting members, and the maintenance request record stages
`loopex.model_request.v2` bytes. Successful settlement retains
bounded summary bytes in `checkpoint_pending`; it neither appends a normal
assistant answer nor completes the parent run. Validate pending progress and
the applicable post-substitution limits first, as above. Only then commit the checkpoint, publish
`context.compacted`, then return to the original staging identity if bounds
permit. A reply after committed abort/deadline is retained as evidence only and
cannot create a checkpoint. An abort committed, or a deadline observed elapsed,
while `checkpoint_pending` likewise wins: the pending summary stays settlement
evidence and no checkpoint is committed. Retain checkpoint tx ID,
expected version and mutation digest. A `commit_unknown` fences mutation and
publication until resolution. A known settled summary may finish its checkpoint
without another provider call. Ambiguous attempts follow ADR 0018 and stop the
episode; checkpoint absence alone says nothing about dispatch. Cancellation
prevents new attempts and follows normal cleanup; accepted checkpoints remain.
Progress `context.compaction_progress` is transient, never checkpoint evidence.

<a id="technical-adr-0043-evidence"></a>
### Evidence

Concept: [Observable consequences](0043-context-compaction-checkpoint.md#concept-adr-0043-consequences).

- Property histories cover complete cut boundaries, contiguous ranges, deterministic
  replay, no cycles and preservation of raw receipts/outcomes.
- Byte/token edges and a small model window where a smaller complete prefix
  fits but the byte-maximal prefix does not. A short greeting exchange ahead of
  a unit too large to join it selects both in excerpt form and progresses in one
  call, with and without a prior checkpoint; a small prefix whose next unit can
  join stays complete; a pair with no fitting or valid quota refuses before
  dispatch; a sole small prefix before a protected tail shows the recorded
  no-progress limitation and its explicit-compact remedy. Old 12 KiB prompts, 10 KiB write
  arguments, large call metadata and settled input-only runs use marked excerpts
  with maximal prior checkpoint data. No silent truncation or cut inside a group.
- Exact fragment offsets, digests, UTF-8 boundaries, escaping expansion, the four
  candidate quotas, whole-request receipt measurement and minimum-excerpt refusal.
  Original facts remain readable, including a sentinel outside both fragments;
  no check claims the model saw that sentinel. Invalid summary, fixed/system
  context overflow and no-progress cases remain named refusals.
- A terminal run whose newest group is a 14-KiB write or four 4-KiB range
  results can release that group and resume after compaction; include cancelled
  and bound outcomes, maximal prior checkpoint and both automatic/explicit paths.
  Follow that group with several large terminal input-only runs and prove
  oldest-first release eventually permits staging. Current-run inputs, completed
  current-run groups at a later staging and open exchanges remain protected; a
  later-staging overflow with no pre-run range refuses by the numeric bound
  without a summary call. Exact sizing of maximal
  summary, largest demonstrated profile, both headers and retained tail must
  establish the fixture's pinned input ceiling before its provider attempt.
- Explicit compact covers a sole terminal group that fits the old window but
  prevents a smaller-model configure; then a separately admitted configure uses
  the new summary. No provider call occurs inside configure itself. Ordinary
  explicit compact over history needing several prefixes makes exactly one call
  and reports `checkpointed`; a second command continues.
- Old question answers and explicit artifact-range results remain exact in
  ordinary projection and original history; only maintenance source may excerpt
  them. No artifact fetch or implicit artifact/reference creation occurs.
- Repeated checkpoints retain only the latest prior summary/carry-forward and
  inherit `source_excerpted`. Inspection, events, snapshots and model rendering
  agree. A model cannot clear the flag by returning a complete-looking summary.
- Small offending terminal groups may grow into bounded summaries under an
  explicit rendering trigger; multiple offending groups require advancing cuts
  until rendering passes. Other triggers still require both strict decreases.
  No-range rendering failure cannot return unchanged. Non-progressing and
  over-limit pending summaries never commit a checkpoint; fault recovery at
  that boundary repeats the check without another provider call. Size-trigger
  fit followed by unsupported rendering refuses without an extra summary.
- Parseable truncated/unknown-stop summary replies fail while their fully validated
  usage remains charged; exact v2 replies cannot prove maintenance completeness.
  Refusal transaction order, standalone result branches, unavailable recovery,
  configured system ceilings, public measurement scopes, standalone command
  refusals/completion reattachment and receipt-reference failure routes have vectors.
- Exact source/summary message rendering, one descriptor per final message,
  revision-4 source-reference bindings and legacy v2/v3 receipt replay. Substituted
  episode/range/digest, missing checkpoint and unknown variant refuse; no source
  descriptor promotes conversation data into system trust. Large-range traversal
  retains bounded pages/buffers and observes cancellation/deadline before dispatch.
- Revision-4 maintenance with and without admitted project/resource-pack state
  records skipped intake and zero optional costs. Unknown dispositions, changed
  captured manifest/selection identities, any optional descriptor, and use of
  maintenance-only dispositions by ordinary or legacy requests refuse.
- Attempt/turn/token/deadline accounting, four-attempt ceiling and no restart reset.
  Pre-first-ordinary maintenance commits the run deadline at its first staged
  request; fault cuts before/after that commit preserve ADR 0013 semantics.
  Owner loss or slow traversal past the fixed pre-staging cutoff ends episode
  and run with `compaction_preparation_deadline` and no fabricated bound; an
  unrepresentable first maintenance deadline keeps the run's existing terminal
  and records `maintenance_deadline_unrepresentable` in the episode. An
  out-of-domain or overflowing clock at episode admission admits no episode and
  makes no call: the run ends `context_preparation_failed` with that cause, and
  a standalone command completes `failed` with zero usage. Non-refusal
  run-owned endings commit the episode terminal first and leave each consecutive
  pair adjacent, including the maintenance settlement then run terminal; a nine-key v2 summary reply fails as incomplete and
  an unreadable one keeps the run's unreadable-answer terminal.
  A one-turn run whose progressing first summary still needs another prefix
  retains that partial checkpoint, then ends with the parent's exact max_turns
  measurements without another dispatch. Standalone rejects that branch;
  absolute-deadline and all legal accounting-source variants have vectors.
  Four progressing summaries that still miss the run-owned target, with parent
  bounds remaining, end both terminals with the measured staging/headroom
  failure and the episode count 4, without a fifth call. The corresponding
  standalone case instead records its exact max_attempts bound.
- Open-thinking-exchange refusal preserves its full prefix; after settlement,
  canonical compaction succeeds without private blocks or signature reuse.
- Recorded maintenance thinking-off override and unsupported-mode refusal;
  actual provider reply limit remains 1,024 and ordinary run settings stay intact.
- Explicit same/different-model selection, no-setting refusal and no fallback.
  Composition resolves the closed plain option before core; malformed/unsupported
  supplied settings and missing admitted routes refuse startup. One runtime's
  choice cannot change another's. Public/per-prompt inputs cannot override it.
- Derive the input ceiling from the summarizer window and captured parent cap,
  test unknown-window fallback and output/system limits, and retain exact origins.
  Active maintenance spends its owning run allowances once. Parent-session
  maintenance leaves delegation counters unchanged; child maintenance appears
  once in child terminal usage and delegation settlement, including overshoot,
  unknown accounting and restart. It consumes no extra child count.
- Restart with changed/absent model selection or changed host catalog retains
  admitted configuration and staged bytes. Missing route/renderer refuses
  scheduling without durable mutation or substitution; restoring the captured
  route/renderer then restarting resumes. An already settled summary still
  completes its checkpoint without an unnecessary provider call.
- Exact host instruction rendering/digest, missing/invalid instruction refusal,
  strict system ceiling, closed source/output shapes and UTF-8/escaping byte
  boundaries; six prose headings do not authorize additional output fields.
- Restart with changed/absent host instructions resumes an admitted episode
  from its retained block; a subsequent episode uses the new option or refuses
  if it is absent. Two runtimes retain distinct blocks. Public create/configure
  cannot replace that host option.
- Direct Runtime, durable and ephemeral composition forward the same exact
  block. Missing/corrupt captured episode data refuses even when the current
  runtime has a valid block; it is not repair authority.
- Fault cuts after source staging, then summary settlement/checkpoint commit/publication, including
  commit_unknown and ambiguous provider attempt; no duplicate dispatch.
- Real long conversation passes the limit and correctly refers to summarized work;
  checkpoint/raw records and restart agree. Include an always-on conversation
  model with an explicitly configured thinking-off summarizer on another admitted
  provider; identify both models and their separately reported usage.

<a id="technical-adr-0043-compatibility"></a>
### Compatibility Mechanics and Alternatives

Concept: [Compatibility and rollback](0043-context-compaction-checkpoint.md#concept-adr-0043-compatibility).

`session.compact`, its bounds and checkpoint/maintenance projections use
ADR 0044's coordinated foreground `/3` and daemon `/4` generations. Apply the
M7 plan's old-offer refusal and independent-client vectors; no old wire decoder
is extended in place to accept this method or its new records.

This strategy uses an explicit host-selected summarizer through the existing
model boundary. It adds no helper role, artifact request path or abandoned-branch
summarization. Its fixed caps are
bounded candidate values, not measured quality claims. Any later strategy or
cap increase changes the proposal/accepted contract explicitly; a failed fixture
cannot be made passing by silently increasing retries.
