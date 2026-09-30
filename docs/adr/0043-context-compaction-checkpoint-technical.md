<a id="technical-depth"></a>
## Technical depth

Concept: [Bounded context compaction checkpoints](0043-context-compaction-checkpoint.md#concept).

<a id="technical-adr-0043-decision"></a>
### Contract

Concept: [Context and decision](0043-context-compaction-checkpoint.md#concept-adr-0043-decision).

**Episode.** Derive identity from the triggering run/staging identity or explicit
compact command ID. Persist frozen configuration, captured session version,
attempt count, bounds, usage and checkpoint progress. Block conflicting mutation
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
Keep user/steer elements in their original order, including those preceding each
group. Preserve current prompt/steer and the newest complete assistant group.
Grow this tail backward by complete groups and intervening inputs while it fits
a 2,048-estimated-token target; the mandatory tail may exceed that target.

From the oldest remaining range, select the largest contiguous prefix ending
at a complete-group boundary that fits both the 16,384-byte encoded source
envelope, including prior summary/carry-forward, and the fully rendered
maintenance request's token/record/depth/cardinality limits with its reply
reserve. Search smaller complete prefixes before refusing; the source cap alone
does not prove the maintenance request fits. If no eligible
raw range exists, make no provider call: explicit compact records idempotent
`unchanged` only if the current request also fits; otherwise preserve the named
staging refusal. When an eligible range exists, explicit compact may produce
a useful bounded checkpoint even if the current model window already fits.
This permits preparation for a smaller model window. Executor-backed tool results use ADR 0041
artifact projections; model-question results retain their exact bounded answer
or disposition without an executor receipt or implicit artifact reference; selection never silently truncates those projections or
omits raw user inputs from the range being summarized. Compaction does not fetch
full artifacts. Prior summary/carry-forward, projected groups and JSON framing
all spend the same 16,384-byte source envelope.
If the first complete group, preceding inputs and prior checkpoint cannot fit
those combined constraints, stop with
`compaction_input_too_large`.

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
per-call overrides refuse. Extend their closed validators and forward through
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
Its bounded source envelope is exactly `{version, prior_checkpoint, messages}`,
with version `loopex.compaction.source.v1`. `prior_checkpoint` is null or exactly
`{checkpoint_id, summary, carry_forward}`, reusing the validated checkpoint's
output shapes. `messages` is a nonempty ordered list of canonical user,
assistant and tool messages from the newly consumed contiguous complete range;
reuse their tool-call generation and terminal-outcome forms. Steer keeps its
existing projected user form. No system instruction, maintenance record or
private thinking is included. Range identities, integrity digest and first-kept
identity remain in the owning records, not duplicated in the source message.
Encode the whole envelope using ADR 0042's compact sorted-key UTF-8 JSON
recipe. Prior checkpoint data and all framing spend the same 16,384-byte cap;
depth/cardinality and whole-request checks still apply. This closes the common
source framing; the pending oversized-content decision must amend the message
projection explicitly before any excerpt or chunk mechanism is implemented.

Maintenance has no tools and reserves 1,024 reply tokens. Retain the parent
configuration version and a separate maintenance configuration/digest with the same exact
model and a verified thinking-off setting: `none`, or `default` only when the
adapter proves omission disables thinking for that exact model. Display this
purpose-specific override; it does not change ordinary run configuration.
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
same staging serializer and estimator. Require strict decrease in both exact
record bytes and estimated tokens. Stop with `compaction_no_progress` otherwise.
If still oversized, another bounded prefix may be summarized within the episode's
remaining attempts. After exhaustion retain checkpoints and the existing named
staging failure; do not restart an automatic episode for the same staging identity.

**Checkpoint.** Retain original lineage/range, newly consumed raw range, prior
checkpoint ID if any, first-kept identity, summary/carry-forward bytes, strategy
`loopex.compaction.reference` revision 1, exact model/reasoning/configuration
version, usage, summary-input digest and ordered covered-record integrity digest.
Ranges extend contiguously without gaps/cycles and never split tool/result groups.
Projection renders a canonical user-context element labelled `compaction_summary`,
with checkpoint identity, covered-range digest and summary provenance; it is
untrusted conversation data and never a system instruction or synthetic tool
result. Adapter vectors fix this rendering. It is followed by
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
- Byte/token edges, a small model window where a smaller complete prefix fits
  but the byte-maximal prefix does not, oversized single turn, fixed/system context that cannot fit,
  invalid summary and no-progress refusal; no silent tool truncation.
- Attempt/turn/token/deadline accounting, four-attempt ceiling and no restart reset.
- Open-thinking-exchange refusal preserves its full prefix; after settlement,
  canonical compaction succeeds without private blocks or signature reuse.
- Recorded maintenance thinking-off override and unsupported-mode refusal;
  actual provider reply limit remains 1,024 and ordinary run settings stay intact.
- Exact host instruction rendering/digest, missing/invalid instruction refusal,
  strict system ceiling, closed source/output shapes and UTF-8/escaping byte
  boundaries; six prose headings do not authorize additional output fields.
- Restart with changed/absent host instructions resumes an admitted episode
  from its retained block; a subsequent episode uses the new option or refuses
  if it is absent. Two runtimes retain distinct blocks. Public create/configure
  cannot replace that host option.
- Fault cuts at summary settlement/checkpoint commit/publication, including
  commit_unknown and ambiguous provider attempt; no duplicate dispatch.
- Real long conversation passes the limit and correctly refers to summarized work;
  checkpoint/raw records and restart agree.

<a id="technical-adr-0043-compatibility"></a>
### Compatibility Mechanics and Alternatives

Concept: [Compatibility and rollback](0043-context-compaction-checkpoint.md#concept-adr-0043-compatibility).

This first strategy uses the session model, no secondary summarizer role,
artifact request path or abandoned-branch summarization. Its fixed caps are
bounded candidate values, not measured quality claims. Any later strategy or
cap increase changes the proposal/accepted contract explicitly; a failed fixture
cannot be made passing by silently increasing retries.
