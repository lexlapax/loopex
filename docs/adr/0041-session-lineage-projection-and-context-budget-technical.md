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
identities. Reused provider IDs in later runs must not select an earlier
result. A terminal fact may supply its committed denied/cancelled/failed/unknown
result; missing facts refuse staging rather than synthesizing success or
raising an uncontrolled owner crash.

Apply ADR 0017's estimator and exact normalized `model_request_committed`
record measurement, including context receipt, envelope and fixed-point
self-size. Preserve its depth/cardinality limits and strict system ceiling.
The 65,536-byte bound is not merely a message or canonical-request bound.
Check before provider intent/dispatch as the accepted staging rules require.

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
- Real multi-prompt task refers correctly to earlier diagnosis and tool evidence.

<a id="technical-adr-0041-compatibility"></a>
### Compatibility Mechanics and Alternatives

Concept: [Compatibility and rollback](0041-session-lineage-projection-and-context-budget.md#concept-adr-0041-compatibility).

Truncating the oldest N runs or tool-result bytes is rejected. Compaction is
an explicit retained substitution. Do not claim byte identity for newly staged
legacy sessions after lineage expands; only already committed requests are
immutable. Root-reader compatibility is covered by the M7 plan's matrix.
