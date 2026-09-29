<a id="technical-depth"></a>
## Technical depth

Concept: [Session lineage projection and context budget](0041-session-lineage-projection-and-context-budget.md#concept).

<a id="technical-adr-0041-decision"></a>
### Projection and Admission

Concept: [Context and decision](0041-session-lineage-projection-and-context-budget.md#concept-adr-0041-decision).

**Present state, read from source on 2026-09-29.**

| Fact | Location |
| --- | --- |
| A prompt installs `[element]` as the run's whole conversation | `apps/loopex/lib/loopex/runtime/session_state.ex`, prompt admission |
| A promoted follow-up does the same | `session_state.ex`, follow-up promotion |
| `elements/2` returns one run's elements | `session_state.ex` |
| Staging reads `SessionState.elements(state.durable, run_id)` | `apps/loopex/lib/loopex/runtime/session_coordinator.ex`, `prepare_model_request` |
| Default context budget is 8,192 | `apps/loopex_composition/lib/loopex_composition.ex`, `context_token_budget/1` |
| The accepted rule | ADR 0010 technical, "Resuming a run versus prompting a session", Projection row |

**Projection order.** The system class, admitted project blocks, then for
each prior run in admission order its user message and each turn's assistant
message followed by that turn's tool results in call order, then the current
run's elements, then a steer message if one is staged. `Conversation.project/2`
stays a pure function of committed elements.

**Run boundaries.** The projection adds no marker between runs. A provider
sees an ordinary alternating conversation. A run that ended with an
assistant message followed directly by the next user message is already
valid for every adapter in the conformance suite.

**Incomplete turns.** A prior run that ended with tool calls lacking results
cannot be projected as-is, because providers reject an unanswered call. Each
such call projects its committed terminal record: `cancelled`, `denied`,
`failed` or `outcome_unknown`. A call with no committed terminal is a defect
and the projection raises, as it does today within a run.

**Admission.** The context measurement of ADR 0017 runs over the full
projected request at prompt admission and at each later staging. The
refusal record and its dimension are unchanged.

**Host default.** The reference host computes
`context_window - reply_reserve` from the model's declared capabilities, with
`reply_reserve` equal to the run's `max_tokens`. When the window is unknown
the host keeps 8,192 and says so.

<a id="technical-adr-0041-evidence"></a>
### Evidence

Concept: [Observable consequences](0041-session-lineage-projection-and-context-budget.md#concept-adr-0041-consequences).

- The first change is a failing test: two prompts in one session, and the
  second staged request contains the first run's elements.
- A follow-up promoted after a terminal projects the same lineage.
- The projection is byte-identical after owner succession and after restart.
- A prior run ended by cancel, bound or failure projects with its terminal
  tool results.
- A session whose lineage exceeds the budget refuses the next prompt at
  admission and makes no provider call.
- The new run's turn, token and deadline accounting start at zero.
- Real provider: the second prompt of a session refers to the first.

<a id="technical-adr-0041-compatibility"></a>
### Compatibility and Rejected Alternatives

Concept: [Compatibility and rollback](0041-session-lineage-projection-and-context-budget.md#concept-adr-0041-compatibility).

- *Keep per-run conversations and amend ADR 0010.* Rejected. It leaves
  Loopex unable to hold a conversation, which the coding-agent proof exists
  to test.
- *Project only the last N runs.* Rejected. It silently drops history. The
  compaction checkpoint is the governed way to shorten a projection.
- *Truncate old tool results to fit.* Rejected for the same reason, and
  because ADR 0010 forbids dropping history to fit.
- *Keep 8,192 as the reference default.* Rejected. It was sized for a
  single run and makes continuity unusable.
