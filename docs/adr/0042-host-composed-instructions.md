# 0042. Host-composed instructions

<a id="concept"></a>
## Concept

Technical depth: [Envelope, bounds and evidence](0042-host-composed-instructions-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-29
- **Decision owner:** Maintainer
- **Supersedes:** [ADR 0010](0010-provider-continuation-and-context-staging.md#concept)
  only in the source of the system class, which moves from a constant in core
  to a host-supplied block, and [ADR 0017](0017-durable-context-admission-budget.md#concept)
  only in the fixed 1,000-token system-class ceiling, which becomes a host
  value with that default
- **Prerequisite for:** M7 outcomes 2 and 7 (draft), accepted before the
  instruction option is written

<a id="concept-adr-0042-decision"></a>
### Context and Decision

Technical depth: [Envelope and bounds](0042-host-composed-instructions-technical.md#technical-adr-0042-decision).

Every model call opens with one instruction block. Today that block is three
sentences compiled into core. No host, profile or command can change it. It
does not tell the model its working directory, its platform or the date.

The vision already assigns this. Core owns exact staging, provenance, budget
accounting and receipts. Prompt selection belongs to hosts and extensions.
ADR 0010 labels the system class "host-owned trusted brain content". The
code simply never gave the host a way in.

**The decision.**

1. **The host supplies the instruction block.** A session is created with an
   instruction block as plain bounded data. Core stages those exact bytes as
   the system class and covers them with the staged request digest.
2. **Core authors no instruction text.** Core keeps a small fallback block
   for a host that supplies none, which is the vision's "versioned base
   prompt". It contains no product or task guidance beyond today's text.
3. **The block has three ordered sections:** base instructions, an
   environment section and an optional host appendix. Admitted project files
   and skills stay in their own classes under ADR 0010 and
   [ADR 0025](0025-resource-packs-and-skill-admission.md#concept). They are
   not copied into the block.
4. **The environment section is facts, not authority.** It names the
   workspace path, the platform, the date and whether the workspace is a Git
   repository. It grants nothing and carries no credential.
5. **The block is committed with the session and fixed for a run.** A host
   may change it between runs. A run in flight keeps the bytes it staged.
6. **The reference host ships one default.** It is one block for every model
   and every task, under 1,000 estimated tokens with the active tool
   definitions, as the vision's minimalism budget requires. There are no
   per-model, per-provider or per-mode variants.
7. **A host may set a larger system-class ceiling for its own block.** The
   ceiling is a host value bounded by the context budget. The reference
   default stays 1,000.

<a id="concept-adr-0042-consequences"></a>
### Observable Consequences

Technical depth: [Evidence](0042-host-composed-instructions-technical.md#technical-adr-0042-evidence).

An embedding host decides how its agent is instructed and can read back the
exact bytes any model call received. The reference command gains an option
to replace or append to the default. Instructions remain trusted host
content: a host that places untrusted text in the block has made a trust
decision of its own.

<a id="concept-adr-0042-compatibility"></a>
### Compatibility and Rollback

Technical depth: [Compatibility and rejected alternatives](0042-host-composed-instructions-technical.md#technical-adr-0042-compatibility).

A session created before this decision carries no instruction block and
projects the fallback, so its requests are unchanged. The session
configuration record gains one additive member. A binary that predates the
member refuses a root that carries it.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
