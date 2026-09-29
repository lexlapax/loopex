<a id="technical-depth"></a>
## Technical depth

Concept: [Child-session tool](0046-child-session-tool.md#concept).

<a id="technical-adr-0046-decision"></a>
### Adapter and Bounds

Concept: [Context and decision](0046-child-session-tool.md#concept-adr-0046-decision).

**Present state, read from source on 2026-09-29.**

| Fact | Location |
| --- | --- |
| Every allowed call runs `executor.module.execute(reference, job, grant, [], progress)` | `apps/loopex/lib/loopex/runtime/session_coordinator.ex` |
| The runtime has one configured executor module | `session_coordinator.ex`; `apps/loopex_composition/lib/loopex_composition.ex` |
| Core exposes `create_session/3`, `command/2`, `next_event/1` and `session_status/2` | `apps/loopex/lib/loopex.ex` |
| Composition has no child-session function | `apps/loopex_composition/lib/loopex_composition.ex` |
| A session record has no origin or lineage field | `apps/loopex/lib/loopex/runtime/session_state.ex` |
| One workspace lease per runtime, with no exclusivity check | `apps/loopex_executor_local/lib/workspace_lease.ex`; `loopex_composition.ex` |
| The durable composition restricts `active_tools` to seven identifiers | `apps/loopex_composition/lib/loopex_composition/durable_options.ex` |

**Routing.** The composition configures one executor module that routes by
tool identifier: the child-session identifier to the child adapter, every
other to the local executor. The router holds no state and adds no
behaviour to the local path. It runs the executor conformance suite.

**The reference definition.** Identifier `loopex.task`, class `effect`,
registered through the runtime's tool set when the host opts in.

| Argument | Bound |
| --- | --- |
| `description` | Non-empty UTF-8 of at most 256 bytes, shown to the operator |
| `prompt` | Non-empty UTF-8 of at most 16 KiB |

**Grant and job.** The call is an ordinary effect. Policy is consulted, a
grant is issued, and the effect intent commits before the adapter runs. The
adapter validates the grant as the local executor does.

**Child identity.** The child's session identifier is derived from the
parent's operation identity and attempt. A retried or recovered operation
therefore finds the same child and creates no second one.

**Child configuration.**

| Setting | Value |
| --- | --- |
| Model and reasoning | The parent's committed configuration |
| Instructions | The host's block, with a host-supplied child appendix |
| Active tools | `loopex.read`, `loopex.grep`, `loopex.find`, `loopex.ls`, unless the host widens it |
| Turn and token bounds | Host values |
| Deadline | The earlier of the host's child deadline and the parent run's remaining time |
| Policy and workspace | The parent's |

**Result.** At most 16 KiB of the child's final assistant text, then a
fixed trailer naming the child session, its terminal outcome and its usage.
A child that ends other than `completed` yields a failed tool result with
that outcome.

**Cancellation.** Cancelling the parent's job aborts the child's run and
waits for its terminal before answering, within the existing cleanup grace.

**Recovery.** After owner loss the parent's effect is unresolved. The
adapter answers reconciliation from the child session's durable terminal.
A child with no terminal is resumed or reported unknown by the ordinary
rules; the parent never re-runs the prompt blindly.

**Writes.** A host that widens the child's tools to `write`, `edit` or
`bash` accepts that both sessions act on one workspace. They never act at
once, because the parent waits.

<a id="technical-adr-0046-evidence"></a>
### Evidence

Concept: [Observable consequences](0046-child-session-tool.md#concept-adr-0046-consequences).

- The router passes the executor conformance suite, and every local tool's
  request and receipt bytes equal those without the router.
- The child's first staged request contains its prompt and instruction
  block and nothing from the parent.
- A child's tool set containing `loopex.task` or `loopex.ask` is refused at
  creation.
- The child's deadline never exceeds the parent's remaining time.
- Parent cancel ends the child before the parent's cancellation settles.
- A crash injected after the child's terminal and before the parent's
  receipt resolves to the child's result with no second child.
- A failed, cancelled or bound-reached child yields a failed tool result.
- A source check finds no child, parent or scheduler concept in
  `apps/loopex`.
- Real provider: a parent delegates one search and uses the answer.

<a id="technical-adr-0046-compatibility"></a>
### Compatibility and Rejected Alternatives

Concept: [Compatibility and rollback](0046-child-session-tool.md#concept-adr-0046-compatibility).

- *The model runs `loopex ask` through `bash`.* This works today with no
  change and is pi's approach. Rejected as the only path: the child's
  policy, bounds and identity would be outside the parent's session and
  invisible to its operator. It remains available to any host.
- *A scheduler in core with parallel children.* Rejected by the vision.
- *Share the parent's history with the child.* Rejected. It defeats the
  purpose, which is a separate context.
- *Charge child usage to the parent's token budget.* Deferred. It needs a
  core accounting change the proof does not require.
