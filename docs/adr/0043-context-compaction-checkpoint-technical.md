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
may overlap summary dispatch.

At most four provider attempts total per episode, including retries allowed
only after proven `not_dispatched`. ADR 0018's two-attempt limit per logical
model operation remains. An active episode consumes a model-call/turn unit for
each summary dispatch and its provider usage under the active run's bounds.
Standalone `compact` accepts explicit `{max_attempts, deadline_ms, token_budget}`
within ceilings 4, 60,000 and 32,768 respectively. The reference `/compact` uses
4/60,000/32,768, displayed before submission; programmatic callers declare them.
All counters and the absolute deadline survive restart. Limit exhaustion prevents
another attempt; final-call token overshoot is reported, not discarded.

**Selection and size.** Select ordered canonical conversation elements, excluding
maintenance records. An assistant reply plus every terminal result of its tool
calls is one indivisible group; an assistant reply with no calls is a group alone.
Keep user/steer elements in their original order, including those preceding each
group. Preserve current prompt/steer and the newest complete assistant group.
Grow this tail backward by complete groups and intervening inputs while it fits
a 2,048-estimated-token target; the mandatory tail may exceed that target.

From the oldest remaining range, select the largest contiguous prefix ending
at a complete-group boundary that fits a 16,384-byte canonical JSON source
envelope, including the prior checkpoint summary and carry-forward. No eligible
raw range means no provider call. Never truncate tool results or omit user facts.
If the first group and preceding inputs cannot fit, stop with
`compaction_input_too_large`.

The summary request uses host instructions with fixed sections: goal, constraints,
progress, decisions, next steps and critical context. It has no tools and reserves
1,024 reply tokens. Full token/record/depth/cardinality preflight still applies.
Reject a model incapable of that reserve or insufficient remaining budget before
dispatch. Output is closed JSON with `summary` UTF-8 at most 4,096 bytes and
`carry_forward` containing arrays `files_read` and `files_changed`, together at
most 2,048 encoded bytes. Bound each path to 1,024 bytes and each list to 32
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
Projection uses a marked summary element with summary provenance, followed by
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
- Byte/token edges, oversized single turn, fixed/system context that cannot fit,
  invalid summary and no-progress refusal; no silent tool truncation.
- Attempt/turn/token/deadline accounting, four-attempt ceiling and no restart reset.
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
