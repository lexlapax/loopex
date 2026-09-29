<a id="technical-depth"></a>
## Technical depth

Concept: [Model-originated questions](0045-model-originated-questions.md#concept).

<a id="technical-adr-0045-decision"></a>
### Tool Class and Interaction Kind

Concept: [Context and decision](0045-model-originated-questions.md#concept-adr-0045-decision).

**Present state, read from source on 2026-09-29.**

| Fact | Location |
| --- | --- |
| An allowed call always reaches `executor.module.execute` | `apps/loopex/lib/loopex/runtime/session_coordinator.ex`, `start_executor_work` |
| Only a policy `defer` begins an interaction | `session_coordinator.ex`, `complete_policy_consultation` |
| `kind` is exactly `choice`; the answer is a choice identifier | `apps/loopex/lib/loopex/interaction.ex`; ADR 0024 technical |
| Expiry is the earlier of the requested duration and the run deadline | ADR 0024 technical |
| The answer method is `session.respond_interaction` | `apps/loopex_protocol/lib/loopex_protocol/session.ex` |
| The reference command presents no interaction | search of `apps/loopex_cli/lib` |
| A host may register a tool; `loopex.` identifiers are reserved | `apps/loopex/lib/loopex/tool_registry.ex`; ADR 0009 |

**Tool class.** A tool definition gains `class`, one of `effect` and
`interaction`. An absent member means `effect`, so every existing
definition is unchanged. The class is part of the definition bytes the
staged request already covers.

**The reference definition.** Identifier `loopex.ask`, registered by the
reference host through the runtime's tool set. Its arguments:

| Argument | Bound |
| --- | --- |
| `question` | Non-empty UTF-8 of at most 2 KiB, the existing prompt bound |
| `choices` | Optional, one to eight labels of at most 256 bytes each |

With `choices` the interaction kind is `choice`; without, `text`.

**The `text` kind.** The answer is `%{text: binary}`, non-empty UTF-8 of at
most 8 KiB. The three digests of ADR 0024 are computed as for `choice`. The
requested duration is 600,000 ms, the existing maximum.

**Dispatch.** After argument validation and a policy `allow`, the
coordinator commits the pending interaction and publishes
`interaction.requested`, in that order. It builds no job and issues no
grant. A policy `defer` on this tool is resolved as `policy_unavailable`:
one call carries one question.

**Tool results.**

| Ending | Model-facing result |
| --- | --- |
| Answered | The answer text, or the chosen label |
| Denied by policy or operator | `denied`, with the category |
| Expired | `expired` |
| Cancelled | The run's cancellation path, unchanged |

**No second evaluation.** ADR 0024 re-evaluates policy after a deferred
answer because a grant may follow. No grant follows here, so the answer
settles the call directly.

**Presentation.** The conversational command prints the question, reads one
line or one choice, and sends the answer. Piped input with no terminal
denies by policy.

<a id="technical-adr-0045-evidence"></a>
### Evidence

Concept: [Observable consequences](0045-model-originated-questions.md#concept-adr-0045-consequences).

- The interaction commits before its event publishes, and no executor
  intent, grant or job exists for the call.
- No provider call is in flight while the interaction is pending.
- Each ending settles the tool call with its distinct result, and the run
  stages its next request.
- After restart the same pending question is re-presented with the same
  identity.
- An answer over the bound, an unknown choice or a second answer is refused
  and changes nothing.
- An answer containing text that asks for authority changes no policy
  decision; the next tool call is still consulted.
- A definition with no `class` dispatches to the executor as before.
- A host policy that denies yields a denial result and no interaction.
- Real provider: a model asks a question and its next turn uses the answer.

<a id="technical-adr-0045-compatibility"></a>
### Compatibility and Rejected Alternatives

Concept: [Compatibility and rollback](0045-model-originated-questions.md#concept-adr-0045-compatibility).

- *Let host policy defer on the tool and an executor return the answer.*
  Rejected. It needs no kernel change, but it routes operator text through
  a grant and a job that perform no effect, and limits answers to choices.
- *End the run and let the operator reply with a follow-up.* Rejected as
  the only path. It works today once lineage projects, but the model cannot
  tell a question from a final answer, and the run's bounds restart.
- *A general workflow engine.* Rejected, as ADR 0024 rejected it.
- *Pause the run deadline while waiting.* Rejected here. It changes the
  run's committed deadline and belongs to its own decision.
