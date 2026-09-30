<a id="technical-depth"></a>
## Technical depth

Concept: [Bounded context compaction checkpoints](0043-context-compaction-checkpoint.md#concept).

<a id="technical-adr-0043-decision"></a>
### Contract

Concept: [Context and decision](0043-context-compaction-checkpoint.md#concept-adr-0043-decision).

**Episode.** Derive identity from the triggering run/staging identity or explicit
compact command ID. Persist frozen configuration, captured session version,
attempt count, bounds, usage and checkpoint progress. Capture its trigger as
`ordinary_limit`, `thinking_headroom` or `explicit`; the thinking trigger also
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
group is eligible. Preserve current prompt/steer and the newest complete assistant group.
Grow this tail backward by complete groups and intervening inputs while it fits
a 2,048-estimated-token target; the mandatory tail may exceed that target.

From the oldest remaining range, select the largest contiguous prefix ending
at a complete-unit boundary that fits both the 16,384-byte encoded source
envelope, including prior summary/carry-forward, and the fully rendered
maintenance request's token/record/depth/cardinality limits with its reply
reserve. Search smaller complete prefixes before refusing; the source cap alone
does not prove the maintenance request fits. If no eligible
raw range exists, make no provider call: explicit compact records idempotent
`unchanged` only if the current request also fits; otherwise preserve the named
staging refusal. When an eligible range exists, explicit compact may produce
a useful bounded checkpoint even if the current model window already fits.
This permits preparation for a smaller model window. Begin with ADR 0041's
canonical projections: executor-backed results use artifact projections and
model-question results retain their exact bounded answer or disposition.
Compaction fetches no artifact and creates no implicit artifact reference.

If no complete prefix fits, select exactly the oldest eligible unit using the
marked serialized-excerpt form below. Coverage still consumes that whole unit;
the checkpoint cut never splits a tool/result group. Try per-end raw-byte
quotas 8,192, 4,096, 2,048, 1,024 and 512, in that order. For each, take the
shortest UTF-8-safe prefix and suffix of at least that quota, at most three
extra bytes per end. Require a nonempty omitted middle and disjoint fragments.
Skip an invalid candidate; select the first whose exact source and complete
maintenance request pass every limit, including the 1,024-token reply reserve.
This is five local sizing candidates, not five provider attempts or a claim to
the largest possible excerpt. JSON escaping can enlarge fragments, so raw
quotas alone never establish fit. If none fits, refuse
`compaction_excerpt_budget_too_small` before provider intent. The prior checkpoint,
instructions and minimum fragments can still be irreducible in a small window.
Neither this refusal nor strict-decrease failure authorizes trimming the protected
tail, dropping prior summary data or opening another automatic episode.

**Summarizer selection.** Add immutable optional `maintenance_model` at the same
startup entrypoints as `maintenance_instructions` below. Durable and ephemeral
composition accept an exact `provider:model` string and resolve it through
ADR 0044's host capability/mapping normalizer. Validate the selected route under
ADR 0048. Direct `Loopex.start_link/1` / `Runtime.start_link/1` receive only the
closed resolved map `{model, reasoning, model_capabilities, provider_mapping}`,
with the same field bounds and combined 2-KiB capability/mapping ceiling as
ADR 0044. Reasoning is verified `none`, or `default` only when its retained
mapping proves omission disables thinking for that exact model. No credential,
route handle, module, provider-option bag or live resolver enters this map.
The verified maintenance mapping has `continuation_required: false`.
Core validates plain data and never consults a catalog or derives a provider
mapping from the conversation model. Composition forwards the resolved option
through runtime `Control`, durable assembly and ephemeral
`SessionOwner.runtime_options/1`.

Absent/nil means unconfigured: ordinary work remains valid, but new maintenance
refuses `maintenance_model_unconfigured`. It never means inherit the parent
model. A host may explicitly select the same model. Invalid supplied selections,
unsupported thinking-off mappings or unavailable configured routes refuse
composition startup before owned runtime/session effects; direct core startup
rejects invalid resolved data. Missing instructions retain their distinct
refusal. No public create/configure/compact or per-prompt field overrides these
host startup settings. ADR 0049 maps the model selection to explicit file/CLI
configuration; it supplies no default summarizer.

At episode admission, retain the parent configuration version and capture the
resolved maintenance selection, instruction block, effective limits and their
origins under a maintenance configuration digest. Derive the maintenance input
ceiling as the minimum of the captured parent input ceiling and the selected
summarizer's known context window minus 1,024; use the labelled 8,192-token input
fallback for an unknown window. Retain the parent's strict system-class ceiling
as a separate check, not permission to exceed the maintenance input ceiling.
Require a valid positive input allowance and compatible model output limit.
Source, complete request, depth and cardinality caps remain unchanged. This
adds no context/reply/spending knobs. Ordinary `max_tokens` governs ordinary
requests; maintenance has its own fixed 1,024-token reply allowance even when
ordinary `max_tokens` is smaller. Parent input/system ceilings and run spending
bounds still apply; the maintenance override does not rewrite them.

Recovery uses the captured model, capabilities, mapping, limits and instructions
even if current runtime options changed or are absent. Missing/corrupt capture
refuses; current settings cannot repair it. Dispatch-required recovery needs the
captured model's admitted provider route and renderer revision, without fallback.
A known settled summary may finish its checkpoint without a new provider call.
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

`version` is nonempty ASCII, at most 64 bytes; `body` is nonempty valid UTF-8,
at most 2,048 bytes. Render
exactly `version + ": " + body`; retain those bytes and their computed SHA-256
digest in maintenance configuration. Apply the session's selected strict
system-class ceiling and complete request preflight; the body cap does not
waive either. Missing instructions refuse `maintenance_instructions_unconfigured`;
unknown fields, invalid text or section bounds refuse
`maintenance_instructions_invalid` at startup validation, before provider intent.
A maintenance refusal preserves the triggering staging identity and its named
failure. Core supplies no fallback, ordinary-session substitution, template
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
missing, substituted or cross-episode references refuse. Both descriptors use
`session` / `session_owned_durable_truth`: this authenticates the committed
source, not the truth of its claims or authority of its instructions.
Their six members and canonical message cost/digest recipe remain unchanged.
Retain exactly one descriptor per final message, with none for the underlying
excerpted messages. Maintenance instructions use ADR 0042's `host_instructions`
variant bound to the captured maintenance configuration. Preserve v2 replay;
preserve ADR 0025's v3 resource receipts too. These new variants require v4
validation and are not accepted under either old revision. Maintenance performs
no optional resource intake. Its `project_resource` member is exactly
`{disposition: "not_evaluated_maintenance", detail: null}`. If an admitted
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
pages/records and two end buffers of at most 8,195 bytes each. Do not collect an
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
dispatch. Output is closed JSON with `summary` at most 4,096 bytes after canonical JSON
string encoding, including quotes and escaping, and `carry_forward` containing
arrays `files_read` and `files_changed`, together at most 2,048 encoded bytes.
The whole encoded summary/carry-forward envelope is at most 6,144 bytes, so
independently maximal members may need to be smaller to leave room for framing. Bound each path to 1,024 bytes and each list to 32
entries. Unknown/invalid/oversize output fails without a hidden repair call.

Measure the next candidate projection before and after substitution using the
same staging serializer and estimator. For a thinking-headroom trigger, compare
the same minimum required projection at `q=0`, with optional resources absent,
so enlarging excerpts after compaction cannot hide the reduction. Its inclusive
byte/input targets govern stopping; other triggers use the ordinary hard limits.
Require strict decrease in both exact
record bytes and estimated tokens. Stop with `compaction_no_progress` otherwise.
If still above the applicable limits or targets, another bounded prefix may be
summarized within the episode's remaining attempts. After exhaustion retain
checkpoints and the existing named
staging or thinking-headroom failure; do not restart an automatic episode for
the same staging identity. A maintenance failure retains its more specific
cause. Once the targets fit, ordinary excerpt/optional admission uses the
remaining capacity below those targets and exact final preflight, as ADR 0044
requires. All maintenance requests keep their own existing hard limits;
the ordinary pre-exchange targets do not halve the summarizer's allowance.

**Checkpoint.** Retain original lineage/range, newly consumed raw range, prior
checkpoint ID if any, first-kept identity, summary/carry-forward bytes, strategy
`loopex.compaction.reference` revision 2, exact model/reasoning/configuration
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
accounting with explicit `compaction` purpose. Successful settlement retains
bounded summary bytes in `checkpoint_pending`; it neither appends a normal
assistant answer nor completes the parent run. Commit the checkpoint, publish
`context.compacted`, then return to the original staging identity if bounds
permit. A reply after committed abort/deadline is retained as evidence only and
cannot create a checkpoint. Retain checkpoint tx ID,
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
  fits but the byte-maximal prefix does not. Old 12 KiB prompts, 10 KiB write
  arguments, large call metadata and settled input-only runs use marked excerpts
  with maximal prior checkpoint data. No silent truncation or cut inside a group.
- Exact fragment offsets, digests, UTF-8 boundaries, escaping expansion, the five
  candidate quotas, whole-request receipt measurement and minimum-excerpt refusal.
  Original facts remain readable, including a sentinel outside both fragments;
  no check claims the model saw that sentinel. Invalid summary, fixed/system
  context overflow and no-progress cases remain named refusals.
- Old question answers and explicit artifact-range results remain exact in
  ordinary projection and original history; only maintenance source may excerpt
  them. No artifact fetch or implicit artifact/reference creation occurs.
- Repeated checkpoints retain only the latest prior summary/carry-forward and
  inherit `source_excerpted`. Inspection, events, snapshots and model rendering
  agree. A model cannot clear the flag by returning a complete-looking summary.
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
  admitted configuration and staged bytes. Missing route/renderer refuses a
  required dispatch without substitution; an already settled summary still
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
