<a id="technical-depth"></a>
## Technical depth

Concept: [Reference host run defaults](0047-reference-host-run-defaults.md#concept).

<a id="technical-adr-0047-decision"></a>
### Values and Measurement

Concept: [Context and decision](0047-reference-host-run-defaults.md#concept-adr-0047-decision).

**Present state, read from source on 2026-09-29.**

| Fact | Location |
| --- | --- |
| `@default_bounds %{max_turns: 16, token_budget: 1_000_000, deadline_ms: 600_000}` | `apps/loopex/lib/loopex/runtime.ex` |
| `@default_sampling %{"max_tokens" => 4_096}` | `runtime.ex` |
| Per-command bounds merge over the runtime defaults | `apps/loopex/lib/loopex/runtime/session_coordinator.ex`, `resolve_bounds` |
| `--max-steps` and `--deadline-ms` map to `max_turns` and `deadline_ms` | `apps/loopex_cli/lib/ask_options.ex`; `apps/loopex_cli/lib/loopex_cli/durable_ask.ex` |
| The ephemeral profile defaults to 16 steps, 600,000 ms and 4,096 tokens | `apps/loopex_composition/lib/loopex_composition/ephemeral/options.ex` |
| ADR 0010 requires a configured value with a default and names no number | ADR 0010 |
| Interaction expiry is at most 600,000 ms and never past the run deadline | ADR 0024 technical |

**Where the values live.** In the reference host's conversational command,
passed as per-command bounds. The reusable composition and core keep their
present defaults.

**Relation to the context budget.** The reply limit is the reserve
subtracted from the model's context window in
[ADR 0041](0041-session-lineage-projection-and-context-budget.md#concept).
Raising the reply limit lowers the room for history by the same amount.

**Measurement.** For each task in the coding-task set the release lane
records turns used, tokens charged, wall time and the largest single reply.
A default is confirmed when every task completes under it with headroom,
and corrected otherwise. The record is retained with the closure evidence.

<a id="technical-adr-0047-evidence"></a>
### Evidence

Concept: [Observable consequences](0047-reference-host-run-defaults.md#concept-adr-0047-consequences).

- The conversational command commits the four values with each run, and
  each flag overrides its value.
- `ask` commits the unchanged values.
- A run that reaches each bound ends `bound_reached` naming it.
- The measurement record exists for every task and supports the final
  values.

<a id="technical-adr-0047-compatibility"></a>
### Compatibility and Rejected Alternatives

Concept: [Compatibility and rollback](0047-reference-host-run-defaults.md#concept-adr-0047-compatibility).

- *No turn limit,* as pi has. Rejected. ADR 0010 requires declared bounds
  so that a run ends with a truthful outcome.
- *Raise core's defaults.* Rejected. Embedding hosts would change behaviour
  without asking.
- *Record the values in the plan only.* Possible, since the choice is
  reversible. A decision record is used because the values bound what a
  default installation can spend.
