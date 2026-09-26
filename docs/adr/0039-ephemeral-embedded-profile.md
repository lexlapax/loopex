<a id="concept"></a>
## Concept

Technical depth: [Profile composition, adapters and proofs](0039-ephemeral-embedded-profile-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-26
- **Decision owner:** Maintainer
- **Supersedes:** nothing. It adds a second composition profile beside the
  durable one. [ADR 0034](0034-provider-credential-handoff-over-bootstrap-channel.md#concept)
  and [ADR 0019](0019-host-owned-provider-protection.md#concept) stay exactly
  as accepted and continue to govern every durable and daemon composition.
- **Prerequisite for:** M6 outcomes 1 to 4, accepted before the in-process
  model adapter, the memory store or the ephemeral composition is written

<a id="concept-adr-0039-decision"></a>
### Context and Decision

Technical depth: [Profile composition](0039-ephemeral-embedded-profile-technical.md#technical-adr-0039-decision).

Loopex is meant to be a minimal coding harness on its own, and small enough to
disappear inside a larger host. Every composition today is the durable one.
It needs:

- a state root on disk;
- the local store;
- a provider companion BEAM, with a built worker artifact and matching digests;
- a named host policy and its identity;
- one pinned model.

That is the right shape for an operator who needs recovery, attachment and
takeover. It is the wrong shape for a host that wants one answer from one
function call, a shell script that wants an answer on stdout, or another agent
that wants to delegate a task and read the result. Each of these today must
either assemble the durable stack or write a second, simpler loop, and the
vision forbids the second: no surface owns an alternate loop.

**Decision.** Loopex has two composition profiles over one unchanged kernel.

1. **Durable** (today's composition, unchanged). The local store, the provider
   companion under ADRs 0019 and 0034, and the daemon. It carries every
   recovery, attachment and takeover guarantee M1 to M5 proved.
2. **Ephemeral** (new). The same session kernel, the same tool, policy,
   skill, bounds and event contracts, composed with:
   - **a memory store** that implements the unchanged store port and passes the
     same store conformance suite. It holds every committed record for the life
     of the VM and nothing after it;
   - **an in-process model adapter** that implements the unchanged model port by
     calling ReqLLM inside the host's VM, selected by a `provider:model`
     string, with each provider's credential read from that provider's own
     environment variable at composition and held only in the adapter's
     process state;
   - **the local executor**, pointed at a temporary ledger root and a named
     workspace.

**Truth statement for the ephemeral profile.** The profile is not a durable
session. Effect intent still commits before dispatch and facts before
publication, inside the memory store, so the kernel's ordering rules hold for
the life of the VM. A VM crash loses the session; the profile makes no recovery
claim and reports none. It never presents itself as durable. A caller that
needs recovery composes the durable profile, and nothing is migrated between
the two.

**Credential rule for the ephemeral profile.** Credentials remain references
until composition:

- the adapter reads each provider's named environment variable once;
- it keeps the value only in its own process state;
- the value never enters a journal record, a public event, progress, a
  diagnostic, a fixture or an executor job.

A provider that needs no credential, such as a local Ollama server, reads none.
The companion's process isolation is what the durable profile adds on top of
this, and the ephemeral profile states plainly that it does not have it.

**Authority rule.** Neither profile has a default host authority. The caller
always names the policy. The profile offers the existing presets, including
`allow-all`, by one word: `policy: :allow_all` in the API, `--allow-all` on the
command line.

**Model selection.** A `provider:model` string selects the model:
`ollama:<model>`, `openai:<model>`, `anthropic:<model>` or
`openrouter:<model>`. When none is given, the ephemeral profile's default is a
configured local Ollama model, so the profile works with no key. The durable
profile keeps its pinned reference model until a later decision on
configuration.

<a id="concept-adr-0039-consequences"></a>
### Observable Consequences

Technical depth: [Adapters and proofs](0039-ephemeral-embedded-profile-technical.md#technical-adr-0039-proofs).

- **Embedding.** An Elixir host calls `Loopex.run/2` for one answer, or
  `start_session/1`, `ask/2`, `history/1` and `stop_session/1` for a
  conversation, with no state root, no companion build and no store setup.
- **Shells and agents.** They run `loopex -p "…"` with `--model`,
  `--output json|text`, `--skill <dir>` and a named policy. The exit status
  reports the run's outcome, not only whether the command started.
- **Operators.** Nothing changes for them. Adding `--state-root` to the
  command, or composing the durable profile in the API, selects today's
  behaviour exactly.
- **Isolation.** A reader can always tell which profile a session ran under. The
  ephemeral profile's effective options name it, and its sessions are absent
  from every durable listing.

<a id="concept-adr-0039-compatibility"></a>
### Compatibility and Rollback

Technical depth: [Compatibility mechanics](0039-ephemeral-embedded-profile-technical.md#technical-adr-0039-compatibility).

This is additive. The durable profile, the public session protocol, the store
format, the executor protocol and the daemon are unchanged. The new API
functions and the `-p` command form are experimental surfaces under the 0.x
policy. The memory store and the in-process adapter are new edge modules
behind unchanged ports, so core's dependency budget is unchanged. Rolling
back is removing the profile: no durable byte depends on it.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
