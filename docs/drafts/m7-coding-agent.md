<a id="concept"></a>
## Concept

Technical depth: [Prerequisites, evidence and compatibility](m7-coding-agent-technical.md#technical-depth).

**Draft, not a registered plan.** This draft records the maintainer's
decision of 2026-09-29: M7 tests whether Loopex is a coding agent, and the
installed durable operator follows it. The register admits an Open successor
only beside an `Accepted` row, and M6 is `In review`, so this pair moves into
`docs/plans/` as the Open candidate when M6 closes.

<a id="concept-plan-purpose"></a>
### Purpose

Technical depth: [Prerequisites and acceptance points](m7-coding-agent-technical.md#technical-plan-prerequisites).

Technical depth: [Comparison basis](m7-coding-agent-technical.md#technical-plan-comparison).

**M7 is the coding-agent proof.** Its product question is:

> Given a real coding problem, can Loopex work on it the way a person expects
> of a coding agent: remember the conversation, follow instructions the host
> wrote, keep going when the context fills, ask when it is unsure, hand a
> bounded piece of work to a helper, and finish the task?

Loopex already has the loop. Within one run the model calls tools, reads
their real output and is called again, with `read`, `write`, `edit` and `bash`
and declared bounds. What is missing sits around the loop:

| Capability | Today | M7 target |
| --- | --- | --- |
| Memory across prompts | Each prompt or follow-up starts a conversation holding only its own text | A new run sees the session's retained history |
| Instructions | One fixed three-sentence block compiled into core | The host composes instructions; core stages and digests them |
| Long tasks | A run that outgrows its context budget fails | Compaction keeps the session working |
| Model control | One model per session; only an output limit is sent | Model and reasoning level are chosen per run |
| Questions | Only a host policy can ask the operator something | The model can ask a question and wait for the answer |
| Conversation surface | One-shot `ask`, then `resume` with flags | A line-oriented conversational command |
| Helpers | None | A host tool runs a bounded child session |
| Proof | Workflow tests of single tasks | A retained set of real coding tasks, completed end to end |

**Shape.** M7 follows the minimal design of the pi coding agent, not the
agent-and-mode design of opencode: four tools, a short prompt, no plan mode
and no todo tool. That matches the rule that the smallest sufficient system
wins. The 2026-09-29 comparison is summarised in the
[technical companion](m7-coding-agent-technical.md#technical-plan-comparison).

<a id="concept-plan-outcomes"></a>
### Outcomes

Technical depth: [Evidence obligations and mapping](m7-coding-agent-technical.md#technical-plan-evidence).

| # | Outcome |
| --- | --- |
| 1 | **Session continuity.** A prompt or promoted follow-up in a session projects the retained lineage of its prior runs, as accepted ADR 0010 already decides |
| 2 | **Host-composed instructions.** The host supplies the instruction block: base text, an environment section and admitted project files. Core stages the exact bytes and binds them by digest. Composition ships a default |
| 3 | **Compaction.** A checkpoint replaces older history in the projection when the context nears its limit, or on an explicit command. Raw records stay in durable history |
| 4 | **Model and reasoning per run.** A run names its model and reasoning level. A session may change either between runs |
| 5 | **Model-asked questions.** The model can ask the operator a question through a tool. The run waits, durably, for an answer, an expiry or a cancel |
| 6 | **Conversational command.** One line-oriented command holds a multi-turn conversation: prompt, watch, steer, answer, follow up. It is a peer surface over the same session contract |
| 7 | **Child-session tool.** A host tool starts a bounded child session with its own prompt and returns its final answer to the parent as a tool result. Core gains no scheduler |
| 8 | **Coding-task demonstration.** A fixed set of real coding tasks runs against a real provider and completes, with outputs retained |

<a id="concept-plan-scope"></a>
### Scope and Non-Goals

Technical depth: [Evidence obligations and mapping](m7-coding-agent-technical.md#technical-plan-evidence).

**Scope.** The eight outcomes, in the durable profile. The ephemeral profile
gains outcomes 2, 4 and 5 where one call can carry them. Operator and
developer documentation changes with each outcome.

**Non-goals.**

- **Modes and planning aids:** no plan mode, no todo tool, no named agent
  types.
- **Prompt engineering in core:** no per-model or per-provider prompt files,
  no learned or optimized prompts.
- **Secondary model calls:** no title generation and no small-model roles.
  Compaction is the only model call the operator did not ask for.
- **Scheduling:** no sub-agent scheduler, no parallel children, no nested
  children, no model switching inside a run.
- **Surface:** no full-screen terminal interface.
- **Other rungs:** no installed distribution, saved configuration, store
  engine or extension activation. No MCP.
- **Freezes:** no public-protocol or embedded-API freeze.

<a id="concept-plan-decisions"></a>
### Design Decisions

Technical depth: [Prerequisites and acceptance points](m7-coding-agent-technical.md#technical-plan-prerequisites).

**What stays.**

- [ADR 0010](../adr/0010-provider-continuation-and-context-staging.md#concept)
  keeps exact staged bytes and already decides that a new prompt projects the
  whole retained lineage. Outcome 1 implements that decision.
- [ADR 0024](../adr/0024-durable-interaction-lifecycle-and-host-policy-authority.md#concept)
  keeps host policy as the only authority. A model's question grants nothing.
- [ADR 0025](../adr/0025-resource-packs-and-skill-admission.md#concept) keeps
  skill and project-file admission.
- The vision keeps "a built-in sub-agent scheduler" out of Loopex. Outcome 7
  is a host tool over ordinary sessions, not a kernel feature.

**Proposed with this draft,** each accepted before the outcome that depends
on it:

| Decision | Outcome | What it decides |
| --- | --- | --- |
| [ADR 0041](../adr/0041-session-lineage-projection-and-context-budget.md#concept) | 1 | A new run projects the session's history; the host sizes the context budget to the model |
| [ADR 0042](../adr/0042-host-composed-instructions.md#concept) | 2, 7 | The host supplies the instruction block; core stages and digests it |
| [ADR 0043](../adr/0043-context-compaction-checkpoint.md#concept) | 3 | A `compact` command and checkpoint record; the session's own model writes the summary |
| [ADR 0044](../adr/0044-run-model-and-reasoning-configuration.md#concept) | 4 | Model and reasoning level are a durable session fact, changed between runs |
| [ADR 0045](../adr/0045-model-originated-questions.md#concept) | 5, 6 | A question is a tool call the session owner handles; one new free-text kind |
| [ADR 0046](../adr/0046-child-session-tool.md#concept) | 7 | An opt-in executor adapter in composition runs one read-only child session |
| [ADR 0047](../adr/0047-reference-host-run-defaults.md#concept) | 6, 8 | The conversational command's bounds: 64 turns, 60 minutes, measured before closure |

**Decisions inside those records that need the maintainer.**

- **Vision readings.** The vision budgets seven built-in tools and no
  built-in sub-agent. ADR 0045 and ADR 0046 read opt-in host tools as
  outside both. Acceptance confirms that, or names a vision amendment.
- **Accepted clauses amended.** ADR 0042 changes the source of ADR 0010's
  system class and ADR 0017's fixed ceiling. ADR 0043 lifts ADR 0010's
  compaction exclusion. ADR 0045 amends one clause each of ADR 0009 and
  ADR 0024.
- **Conflict with a proposed record.** ADR 0044 conflicts with clause 7 of
  Proposed ADR 0037, which fixes the model at composition start.

**Open reconciliations.**

- **Draft numbering.** The installed operator, store engine and extension
  drafts keep their file names and numbers until M6 closes. They move one
  place later at that point, and the proposed ADRs 0036 to 0038 that name M7
  are corrected with them.
- **Ephemeral continuity.** One ephemeral call is one run. Whether an
  embedding host can hold an ephemeral session across prompts is decided with
  outcome 1.
- **Release label.** This draft claims no version.

<a id="concept-plan-verification"></a>
### How Each Outcome Is Verified

Technical depth: [Evidence obligations and mapping](m7-coding-agent-technical.md#technical-plan-evidence).

Verification is the current suite plus the two check commands. The fast check
proves each outcome credential-free with the model fake. The release check
gains the coding-task lane of outcome 8 against the real provider. The first
change of the milestone is a failing test for outcome 1, because the present
behaviour is read from source and not yet shown by a run.

<a id="concept-plan-rollout"></a>
### Rollout and Compatibility

Technical depth: [Compatibility, migration and rollback](m7-coding-agent-technical.md#technical-plan-compatibility).

M7 changes core's runtime library, which M6 left untouched. The staged
request changes shape, so its version changes visibly. Existing durable roots
open unchanged, and a session created before M7 continues under it. The
session protocol stays experimental.

<a id="concept-plan-workstreams"></a>
## Workstreams

Technical depth: [Workstreams and rejoin order](m7-coding-agent-technical.md#technical-plan-ownership).

Outcomes 1 to 3 share one owner and run in order. The others rejoin after
outcome 1. The coding-task lane is written first and turns green last.

## Progress and Evidence

Every row reads `Open` while the draft is unregistered.

| # | State | Evidence |
| --- | --- | --- |
| 1 | Open | Each run's conversation starts with its own prompt alone; read from source on 2026-09-29, not yet shown by a test |
| 2 | Open | One fixed instruction block is compiled into core and ignores session state |
| 3 | Open | No compaction exists; a run over its context budget fails |
| 4 | Open | The model is fixed per session; the adapter sends no reasoning setting |
| 5 | Open | The only interaction kind is a policy-originated `choice` |
| 6 | Open | No conversational command exists |
| 7 | Open | No child-session tool exists |
| 8 | Open | No coding-task set exists |

## Governance Records

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
| Closure | — | — | — |
