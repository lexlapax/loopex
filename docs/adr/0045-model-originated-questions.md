# 0045. Model-originated questions

<a id="concept"></a>
## Concept

Technical depth: [Tool class, interaction kind and evidence](0045-model-originated-questions-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-29
- **Decision owner:** Maintainer
- **Supersedes:** [ADR 0024](0024-durable-interaction-lifecycle-and-host-policy-authority.md#concept)
  only in two clauses: that a policy `defer` is the sole producer of an
  interaction, and that `kind` is exactly `choice`.
  [ADR 0009](0009-tool-executor-and-grant-contracts.md#concept) only in that
  every allowed tool call reaches an executor
- **Prerequisite for:** M7 outcomes 5 and 6 (draft), accepted before the
  tool class is written

<a id="concept-adr-0045-decision"></a>
### Context and Decision

Technical depth: [Tool class and interaction kind](0045-model-originated-questions-technical.md#technical-adr-0045-decision).

A coding agent that is unsure should be able to ask. Today it cannot. The
only question Loopex can put to an operator comes from a host policy that
deferred a tool decision, and the only answer is one of up to eight offered
choices. The reference command does not present even those.

ADR 0024 rejected a general question engine "because the only proven
producer is policy `defer`". The coding-agent proof supplies the second
producer. Two accepted mechanisms stand in the way: every allowed tool call
goes to an executor, and a question has no effect for an executor to
perform.

**The decision.**

1. **A question is a tool call.** The model asks by calling one tool with
   its question. The answer comes back as that call's tool result.
2. **The session owner handles it, not an executor.** A tool definition may
   declare the class `interaction`. An allowed call of that class commits a
   pending interaction. No grant is minted and no executor runs.
3. **Host policy decides first.** The policy is consulted as for any tool
   call. A host with nobody to ask denies, and the model receives a denial
   it can act on.
4. **One new kind, `text`.** The operator answers in bounded free text. The
   model may also offer choices, which uses the existing `choice` kind.
5. **The answer is content, not authority.** It enters the conversation as
   a tool result. It grants nothing, changes no policy and widens no tool
   set. A later tool call is still decided by host policy.
6. **The lifecycle is ADR 0024's.** The interaction is durable, survives
   restart, and ends as answered, denied, expired or cancelled. Each ending
   gives the model a distinct tool result, and the run continues.
7. **Waiting counts against the run deadline,** as ADR 0024 already fixes.
8. **The tool is opt-in.** It is not in the default active set. The
   conversational command activates it; one-shot and headless hosts do not.

**Vision reading for the maintainer.** The vision budgets "seven
conformance-tested built-in tool implementations". This tool has no
executor implementation, so this record reads it as outside that count.
Acceptance confirms that reading, or names a vision amendment.

<a id="concept-adr-0045-consequences"></a>
### Observable Consequences

Technical depth: [Evidence](0045-model-originated-questions-technical.md#technical-adr-0045-evidence).

In a conversation, the operator sees the model's question, types an answer,
and the run continues with it. A run left unanswered ends the question by
expiry and carries on or stops by its own judgment. An independent client
receives the question through the existing interaction event and answers
with the existing method.

<a id="concept-adr-0045-compatibility"></a>
### Compatibility and Rollback

Technical depth: [Compatibility and rejected alternatives](0045-model-originated-questions-technical.md#technical-adr-0045-compatibility).

The `text` kind and the tool class are additive to the experimental session
protocol. A client that knows only `choice` sees an unknown kind and cannot
answer it; the interaction expires. A session that never activates the tool
is unchanged.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
