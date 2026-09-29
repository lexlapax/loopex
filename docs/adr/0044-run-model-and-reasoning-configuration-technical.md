<a id="technical-depth"></a>
## Technical depth

Concept: [Run model and reasoning configuration](0044-run-model-and-reasoning-configuration.md#concept).

<a id="technical-adr-0044-decision"></a>
### Record and Options

Concept: [Context and decision](0044-run-model-and-reasoning-configuration.md#concept-adr-0044-decision).

**Present state, read from source on 2026-09-29.**

| Fact | Location |
| --- | --- |
| The model is a coordinator launch option | `apps/loopex/lib/loopex/runtime/session_coordinator.ex`, `init` |
| The model string is durable only inside each committed request | `apps/loopex/lib/loopex/runtime/session_state.ex`; `apps/loopex/lib/loopex/model.ex` |
| `session.configured` does not exist in code | search of `apps/*/lib` |
| `loopex resume` accepts no model flag and performs no model comparison | `apps/loopex_cli/lib/loopex_cli.ex` |
| Core validates `max_tokens` and plain data in `sampling`, and names no other key | `model.ex`, `validate_semantics` |
| The durable composition accepts exactly `%{"max_tokens" => n}` | `apps/loopex_composition/lib/loopex_composition/durable_options.ex` |
| The adapter passes no reasoning option | `apps/loopex_llm_reqllm/lib/loopex/llm/req_llm.ex`, `call_options/3` |
| ReqLLM 1.24.0 accepts `reasoning_effort` and `reasoning_token_budget` | `deps/req_llm/lib/req_llm/provider/options.ex` |

**The configuration record.**

| Member | Content |
| --- | --- |
| `model` | Exact model identity string, as the adapter names it |
| `reasoning` | One of `none`, `low`, `medium`, `high`, `default` |
| `configuration_version` | Integer, incremented per change |

The active tool set stays where ADR 0009 commits it. It joins this record
only if a later decision lets it change after session start.

**The command.** `configure` is admitted only while the session is settled.
It is idempotent under its command identity. A refused configuration commits
a refusal record and changes nothing.

**Request staging.** `reasoning` enters the canonical request as a sampling
member, so the staged request digest covers it. `default` omits the member,
which keeps requests staged before this decision byte-identical.

**Adapter mapping.** The ReqLLM adapter maps `none`, `low`, `medium` and
`high` to the same `reasoning_effort` values. It sends no token budget. The
wider ReqLLM values are not admitted.

**Capability.** The adapter's capability answer for a model gains
`reasoning_levels`, the subset it accepts. An unknown model answers with
`default` alone.

**Provider-affine state.** On a change of model or provider, the projection
drops reasoning content blocks and provider tool-call metadata from prior
assistant messages, and keeps text, tool calls and tool results. Tool-call
identifiers are normalized as the vision's conformance list requires.

<a id="technical-adr-0044-evidence"></a>
### Evidence

Concept: [Observable consequences](0044-run-model-and-reasoning-configuration.md#concept-adr-0044-consequences).

- A configuration change commits one record and publishes one event, and a
  snapshot carries the current configuration.
- A change submitted during a run is refused.
- A run recovered after restart stages with the configuration committed at
  its admission.
- A level outside the model's declared subset is refused.
- A request staged with `default` equals one staged before this decision.
- The adapter conformance suite covers same-model continuation,
  compatible-model continuation, a model change between runs and tool-call
  identifier normalization.
- Real provider: one session completes two runs on two models, and one run
  at `high` reports reasoning usage.

<a id="technical-adr-0044-compatibility"></a>
### Compatibility and Rejected Alternatives

Concept: [Compatibility and rollback](0044-run-model-and-reasoning-configuration.md#concept-adr-0044-compatibility).

- *Keep the model fixed at composition start,* as Proposed ADR 0037 has it.
  Rejected. It leaves the session's model unrecorded and resume unchecked.
- *Switch models inside a run.* Rejected. A run is one bounded unit with one
  staged configuration.
- *Pass the provider's own reasoning options through.* Rejected. It puts
  provider vocabulary into a committed core record.
- *A reasoning token budget.* Deferred. A level is enough for the proof.
