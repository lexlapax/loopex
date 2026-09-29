<a id="technical-depth"></a>
## Technical depth

Concept: [M7 coding-agent proof](m7-coding-agent.md#concept).

<a id="technical-plan-prerequisites"></a>
### Prerequisites and Acceptance Points

Concept: [Purpose](m7-coding-agent.md#concept-plan-purpose).

Concept: [Design decisions](m7-coding-agent.md#concept-plan-decisions).

M6 closes first. The seven decisions the Concept plan lists are proposed as
ADRs, numbered when proposed, and each is accepted before the implementation
that depends on it. None exists yet, so this draft links none. Accepted
decisions that constrain the work:

| Decision | Constraint on M7 |
| --- | --- |
| [ADR 0010](../adr/0010-provider-continuation-and-context-staging.md#concept) | Staged bytes are committed with intent and digest-bound. A prompt to a settled session projects the whole retained lineage |
| [ADR 0011](../adr/0011-session-input-algebra-and-streaming.md#concept) | Prompt, steer and follow-up admission rules are unchanged |
| [ADR 0017](../adr/0017-durable-context-admission-budget.md#concept) | Context admission is budgeted and refuses by named dimension |
| [ADR 0021](../adr/0021-compacted-provider-accounting-provenance.md#concept) | Provider accounting provenance is retained |
| [ADR 0024](../adr/0024-durable-interaction-lifecycle-and-host-policy-authority.md#concept) | Interactions are durable, bounded and grant nothing |
| [ADR 0039](../adr/0039-ephemeral-embedded-profile.md#concept) | The ephemeral profile's credential scope and cleanup limits are unchanged |

Vision sections that bind the work: what Loopex is not (§3.2), compaction
(§12.5), model identity and provider state (§13.4) and the context pipeline
(§13.5).

<a id="technical-plan-comparison"></a>
### Comparison Basis

Concept: [Purpose](m7-coding-agent.md#concept-plan-purpose).

Read from source on branch `m6` on 2026-09-29:

| Fact | Location |
| --- | --- |
| Turn continuation and bound order | `apps/loopex/lib/loopex/runtime/session_coordinator.ex` `settle_turn/2`; `apps/loopex/lib/loopex/bounds.ex` |
| Fixed instruction block | `session_coordinator.ex` `system_block/1` |
| Request options: model, active tools, `max_tokens`, deadline | `session_coordinator.ex` `model_candidate/5` |
| A run's conversation starts as its prompt alone | `apps/loopex/lib/loopex/runtime/session_state.ex`, both `Map.put(state.conversation, run_id, [element])` sites |
| Reasoning is streamed back and no setting is sent | `apps/loopex_llm_reqllm/lib/loopex/llm/req_llm.ex` |
| Tools: read, write, edit, bash, grep, find, ls | `apps/loopex_executor_local/lib/coding_tools.ex` |
| Interaction kind is exactly `choice` | `apps/loopex/lib/loopex/interaction.ex` |

The pi and opencode findings came from their public repositories and
documentation, read through a summarising fetcher and not line by line. Both
projects treat these as essential: the tool loop, the four tools, a short
composed prompt with project files, session persistence, compaction, and
input queued during a run. They differ on step limits, permissions,
sub-agents, plan mode, todos, per-model prompts and secondary model calls.
opencode has all of those; pi has none built in.

<a id="technical-plan-evidence"></a>
### Evidence Obligations and Mapping

Concept: [Outcomes](m7-coding-agent.md#concept-plan-outcomes).

Concept: [Scope and non-goals](m7-coding-agent.md#concept-plan-scope).

Concept: [How each outcome is verified](m7-coding-agent.md#concept-plan-verification).

| # | Fast check | Release check |
| --- | --- | --- |
| 1 | The second run's staged request contains the first run's prompt, assistant messages and tool results in committed order. The projection is rebuilt identically after owner succession and restart. Accounting for the new run starts at zero | The second prompt of a real session refers to the first |
| 2 | Staged bytes equal the host's composed block. The digest changes when the block changes. An oversize or malformed block is refused before dispatch. Core contains no instruction text beyond the envelope | The default block drives a real task |
| 3 | The checkpoint records input range, summary, model identity, usage and integrity digest. Projection substitutes it and keeps the first later raw record verbatim. Raw records remain readable. A crash during compaction leaves the prior projection. Tool receipts and effect outcomes are unchanged by a summary | A real session passes its context limit and continues |
| 4 | Run configuration commits model and reasoning level. The adapter conformance suite covers the setting. An incompatible change strips provider-affine state | One session runs two models in successive runs |
| 5 | The question is a committed interaction. The run holds no provider call while it waits. Answer, expiry and cancel each settle the tool call with a distinct result. Replay after restart re-presents the same question. The answer passes through host policy and grants nothing | A real model asks and uses the answer |
| 6 | The command drives the public session contract only. Steer, follow-up, question and interrupt paths each have a test over a pseudo-terminal or piped input | Attended conversation of at least three prompts |
| 7 | The child has its own session identity, bounds and policy. The parent's tool result names the child. Parent cancel cancels the child. A child cannot start a child. Child failure is an ordinary tool failure | A real parent delegates one search task |
| 8 | The task set and its acceptance checks are fixtures in the repository | Every task completes against the real provider. Transcripts and workspace diffs are retained outside the repository with digests |

Each coding task states its starting workspace, its prompt and a check that
decides pass or fail without reading the model's prose, such as a test suite
that must pass. A task that passes only on retry is a failure to explain.

<a id="technical-plan-ownership"></a>
### Workstreams and Rejoin Order

Concept: [Workstreams](m7-coding-agent.md#concept-plan-workstreams).

Outcomes 1 to 3 change the same projection and staging code and run serially
in that order under one owner. Outcomes 4 and 5 may run in parallel with them
after outcome 1 rejoins. Outcome 6 depends on 5. Outcome 7 depends on 1 and 2.
Outcome 8 is written first as a failing lane and turns green last.

<a id="technical-plan-compatibility"></a>
### Compatibility, Migration and Rollback

Concept: [Rollout and compatibility](m7-coding-agent.md#concept-plan-rollout).

- The instruction envelope and the projection are covered by the staged
  request digest, so the change is visible in every retained request.
- New record kinds for compaction, model-asked questions and run
  configuration are additive. A prior binary that meets one refuses the root
  and does not guess.
- A run in flight at upgrade finishes under the bytes it staged.
- Rollback proof: a root written by M7 without the new record kinds opens
  under the M6 binary.
