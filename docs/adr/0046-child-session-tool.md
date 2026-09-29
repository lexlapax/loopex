# 0046. Child-session tool

<a id="concept"></a>
## Concept

Technical depth: [Adapter, bounds and evidence](0046-child-session-tool-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-29
- **Decision owner:** Maintainer
- **Supersedes:** nothing
- **Depends on:** [ADR 0041](0041-session-lineage-projection-and-context-budget.md#concept),
  [ADR 0042](0042-host-composed-instructions.md#concept) and
  [ADR 0044](0044-run-model-and-reasoning-configuration.md#concept)
- **Prerequisite for:** M7 outcome 7 (draft), accepted before the adapter
  is written

<a id="concept-adr-0046-decision"></a>
### Context and Decision

Technical depth: [Adapter and bounds](0046-child-session-tool-technical.md#technical-adr-0046-decision).

A search across a large codebase can fill a conversation with output the
main task never needs again. Coding agents handle this by handing a bounded
piece of work to a helper with its own context, and keeping only its answer.

The vision excludes "a built-in sub-agent scheduler" from Loopex and its
minimalism budget says "no built-in sub-agent". It also says such
capabilities "may exist in hosts, adapters, extensions". The maintainer's
direction of 2026-09-29 is a host tool.

**The decision.**

1. **Core does not change for this.** No scheduler, no parent field and no
   child concept enter the kernel. A child is an ordinary session.
2. **The tool is an executor adapter in the host's composition.** It
   implements the existing executor behaviour. Its job is to create a
   session, submit one prompt, wait for the terminal, and return the final
   answer.
3. **One child at a time, one level deep.** The parent run waits for the
   tool result like any other. A child's tool set never contains this
   tool or the question tool.
4. **The child starts empty.** It receives the prompt the parent wrote and
   the host's instruction block. It does not receive the parent's history.
5. **The child is read-only by default.** Its tools are `read`, `grep`,
   `find` and `ls`. A host may widen that set explicitly.
6. **The child has its own bounds and the same policy.** The host sets its
   turn and token bounds. Its deadline never outlasts the parent's. Every
   child tool call is decided by the same host policy as the parent's.
7. **The result names the child.** The parent's tool result carries the
   child's final text, its session identity, its terminal outcome and its
   usage. The operator can open the child session to read everything it
   did.
8. **The tool is opt-in.** It is in no default active set.

**Vision reading for the maintainer.** This record reads "built-in" as
"in the kernel or active by default". An opt-in adapter in the reference
host's composition is outside it. Acceptance confirms that reading, or names
a vision amendment.

<a id="concept-adr-0046-consequences"></a>
### Observable Consequences

Technical depth: [Evidence](0046-child-session-tool-technical.md#technical-adr-0046-evidence).

A model can delegate a search and get back a short answer. The session list
shows child sessions as sessions. Child usage is reported but is not charged
to the parent's token budget, so the host's child bounds are the limit on
what delegation can spend.

<a id="concept-adr-0046-compatibility"></a>
### Compatibility and Rollback

Technical depth: [Compatibility and rejected alternatives](0046-child-session-tool-technical.md#technical-adr-0046-compatibility).

Nothing durable changes shape. Removing the adapter removes the tool, and
sessions that used it keep their tool results. The ephemeral profile does
not offer the tool.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
