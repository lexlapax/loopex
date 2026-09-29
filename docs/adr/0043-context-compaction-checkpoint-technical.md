<a id="technical-depth"></a>
## Technical depth

Concept: [Context compaction checkpoint](0043-context-compaction-checkpoint.md#concept).

<a id="technical-adr-0043-decision"></a>
### Record and Trigger

Concept: [Context and decision](0043-context-compaction-checkpoint.md#concept-adr-0043-decision).

**Present state, read from source on 2026-09-29.** No compaction exists in
code. A staged request over the context budget makes no provider call and
ends the run `failed(context_budget_exceeded, false)`. The vision names a
`compact` session command, a `context.compacted` event and a
`context.compaction_progress` progress kind, and lists the checkpoint fields
in §12.5.

**The checkpoint record.** It carries the vision's fields:

| Member | Content |
| --- | --- |
| `input_range` | First and last summarized record identities, and the lineage they belong to |
| `summary` | Bounded UTF-8 under the fixed outline |
| `carry_forward` | Structured fields: files read, files changed |
| `strategy` | Strategy identity and revision; `loopex.compaction.reference` revision 1 |
| `model` | Model and provider identity, and usage of the summarizing call |
| `first_kept` | Identity of the first later raw record kept verbatim |
| `integrity_digest` | Digest over the ordered summarized record identities |

**Cut point.** The cut falls only on a turn boundary: after a turn's last
tool result, or after an assistant message with no tool calls. A tool call
is never separated from its result. The tail kept verbatim is the newest
turns whose estimate fits the host's `keep_recent_tokens`.

**Projection.** The system class, project blocks, then one user-role
message carrying the summary inside a marked summary element, then the
records from `first_kept` onward. A later checkpoint's input range may
include an earlier checkpoint's summary, and then supersedes it in the
projection.

**Trigger.** With `B` the context budget and `R` the host's reserve, the
host compacts when the estimate of the next request exceeds `B - R`. The
estimate is ADR 0017's estimator. Core evaluates the threshold; the host
supplies `R` and `keep_recent_tokens`.

**The summarizing call.** It is an ordinary committed model attempt under
[ADR 0018](0018-provider-attempt-authority-and-recovery.md#concept), with an
empty tool set. Its input is the serialized range, with each tool result
bounded to a fixed number of bytes. Its usage is charged to the run in
flight, or recorded against the session when no run is active.

**Commit order.** The summarizing attempt settles, then the checkpoint
commits, then `context.compacted` publishes, then the next request stages
against the new projection. A crash before the checkpoint commit leaves the
prior projection; the attempt's usage stays recorded.

<a id="technical-adr-0043-evidence"></a>
### Evidence

Concept: [Observable consequences](0043-context-compaction-checkpoint.md#concept-adr-0043-consequences).

- The record carries every member above, and the integrity digest
  recomputes from the journal.
- The projection after compaction holds the summary and the verbatim tail,
  and no summarized record.
- Every summarized record remains readable through the existing replay
  surface.
- No cut separates a tool call from its result, across a property test of
  generated histories.
- Tool receipts, effect outcomes and interaction records are byte-identical
  before and after.
- A crash injected at each commit step leaves either the prior projection or
  the complete checkpoint.
- A compaction whose summary itself cannot fit ends with a named refusal and
  no checkpoint.
- A run that would have failed for context compacts and completes.
- Real provider: a session passes its context limit and continues with a
  correct reference to summarized work.

<a id="technical-adr-0043-compatibility"></a>
### Compatibility and Rejected Alternatives

Concept: [Compatibility and rollback](0043-context-compaction-checkpoint.md#concept-adr-0043-compatibility).

- *Prune old tool outputs without a summary.* Rejected as the only
  mechanism. It loses facts with no record of what was lost. It may return
  later as a second strategy under the same record.
- *A smaller, cheaper model for summaries.* Rejected for now. It adds a
  second model role and a second credential path for one call.
- *Compaction owned entirely by the host.* Rejected. The projection is
  core's, and a substitution core cannot verify would break exact staging.
- *Delete summarized records.* Rejected by the vision.
