<a id="concept"></a>
## Concept

Technical depth: [Profile composition, adapters and proofs](0039-ephemeral-embedded-profile-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-26
- **Decision owner:** Maintainer
- **Supersedes:** in part.
  - It scopes [ADR 0019](0019-host-owned-provider-protection.md#concept)'s
    rules to the durable profile. Those rules are: every provider invocation in
    a separate provider BEAM, and `LOOPEX_PROVIDER_API_KEY` as the only
    credential source. 0019's technical companion itself says restoring
    shared-VM provider handling "requires a new decision"; this is that
    decision, for the ephemeral profile only.
  - It likewise scopes
    [ADR 0034](0034-provider-credential-handoff-over-bootstrap-channel.md#concept)'s
    bootstrap-channel handoff to the durable profile.
  - Both accepted records stay byte-for-byte as accepted. For every durable and
    daemon composition they govern exactly as before.
- **Prerequisite for:** M6 outcomes 1 to 4, accepted before the in-process
  model adapter, the memory store or the ephemeral composition is written

<a id="concept-adr-0039-decision"></a>
### Context and Decision

Technical depth: [Profile composition](0039-ephemeral-embedded-profile-technical.md#technical-adr-0039-decision).

Loopex is meant to be a minimal coding harness on its own, and small enough to
disappear inside a larger host. Every composition today is the durable one. It
needs:
- a state root on disk and the local store;
- a provider companion BEAM, with a built worker artifact and matching digests;
- a named host policy;
- one pinned model.

That is the right shape for an operator who needs recovery, attachment and
takeover. It is the wrong shape for:
- a host that wants one answer from one function call;
- a shell script that wants an answer on stdout;
- another agent that wants to delegate a task and read the result.

Each of these today must either assemble the durable stack or write a second,
simpler loop, and the vision forbids the second: no surface owns an alternate
loop.

**Decision.** Loopex has two composition profiles over one unchanged kernel.

1. **Durable** (today's composition). The local store, the provider companion
   under ADRs 0019 and 0034, and the daemon. It carries every recovery,
   attachment and takeover guarantee M1 to M5 proved.
2. **Ephemeral** (new). The same session kernel, with the same tool, policy,
   skill, bounds and event contracts, composed with:
   - **a memory store** behind the unchanged store port. It is the pure store
     state the local store already replays, held in a supervised process, and
     proved by the same store conformance suite. It holds every committed record
     for the life of the runtime and nothing after it. The profile composes no
     artifact store, so oversized tool output is truncated, not spilled;
   - **an in-process model adapter** behind the unchanged model port. It calls
     ReqLLM inside the host's VM. A `provider:model` string selects the model,
     and each provider's credential is read from that provider's own
     environment variable at composition;
   - **the local executor**, pointed at a temporary root and a named workspace.

   The profile is assembled by composition, not by core: composing edges is
   what the dependency direction keeps out of the kernel.

**Truth statement for the ephemeral profile.**
- It is not a durable session.
- Effect intent still commits before dispatch, and facts before publication,
  inside the memory store, so the kernel's ordering rules hold for the life of
  the runtime.
- Losing the VM loses the session. The profile makes no recovery claim, reports
  none, and never presents itself as durable.
- A caller that needs recovery composes the durable profile, and nothing is
  migrated between the two.

**Credential rule for the ephemeral profile.**
- **Reading:** credentials remain references until composition. The composition
  reads the provider's named environment variable once and places the value
  only in the adapter's configuration inside the runtime.
- **Passing:** the adapter passes it explicitly on every call, so ReqLLM's own
  ambient key lookup is never used.
- **Never written by Loopex:** the value never enters a journal record, a
  public event, progress, a diagnostic, a trace, a log line Loopex emits, a
  fixture or an executor job. The adapter also suppresses ReqLLM's stream-start
  error line for its own attempt process. Crash reports from ReqLLM's own
  processes, and crash dumps, belong to the host's logging and are the accepted
  exception below.
- **No key needed:** a provider that needs none, such as a local Ollama server,
  reads none.
- **What the durable profile adds:** process isolation through the companion.
  The ephemeral profile states plainly that it does not have it.

**Host hygiene for the ephemeral profile.** The adapter runs inside a host that
may do other things. So before ReqLLM starts, it turns off:
- ReqLLM's automatic loading of a `.env` file from the working directory;
- ReqLLM's unverified-model warning.

It also names every model inline, so no model catalog is consulted.

**Authority rule.** Neither profile has a default host authority. The caller
always names the policy:
- **In the API:** a module implementing `Loopex.Policy`. Composition ships no
  policy of its own, because host policy belongs to the host.
- **On the command line:** `--policy allow-all|shell-allowlist|refuse-all`,
  which the reference CLI maps to its own policy modules.

<a id="concept-adr-0039-relation-0019"></a>
### What Changes Relative to ADR 0019

Technical depth: [Shared-state and diagnostic facts](0039-ephemeral-embedded-profile-technical.md#technical-adr-0039-relation-0019).

ADR 0019 moved the provider out of the host VM for three reasons. The
ephemeral profile answers each one as follows.

1. **An adapter must not change the host's logger, group leaders or shared
   ReqLLM supervision.** The in-process adapter changes none of them:
   - it installs no logger filter or handler;
   - it touches no group leader;
   - it never restarts ReqLLM's supervision tree.

   It does set two ReqLLM application settings before first starting ReqLLM:
   automatic `.env` loading off, and the unverified-model warning off. That is a
   visible, named change to the host's ReqLLM configuration, and it happens
   only if the host has not already started ReqLLM.
2. **ReqLLM's asynchronous diagnostics cannot be proved delivered or clean.**
   ReqLLM's own failure paths can log inspected reasons, crash reports from its
   stream and connection processes can carry request state, and a VM crash dump
   can hold anything.
   - The ephemeral profile accepts that these reach the host's logger and
     crash-dump configuration, which the host owns.
   - The adapter's witness drives each path with a canary credential and must
     find it absent under the default logger configuration.
   - The reference `ask` command closes the paths itself: logger off, its own
     rendered lines, crash dumps disabled.
   - A library host is told the same obligation in the developer guide.
3. **`LOOPEX_PROVIDER_API_KEY` is the only credential source.** In the ephemeral
   profile each provider has its own variable, read once at composition and
   passed explicitly on every call. The durable profile keeps the single
   source.

What the ephemeral profile gives up is process isolation for the credential and
for provider diagnostics. That trade is the point of the profile, and it is
stated wherever the profile is offered.

**Model selection.** A `provider:model` string selects the model:
`ollama:<model>`, `openai:<model>`, `anthropic:<model>` or
`openrouter:<model>`.
- When none is given, the ephemeral profile uses `LOOPEX_MODEL`, and then the
  local default `ollama:llama3.2`, so the profile works with no key.
- The durable profile keeps its pinned reference model unless a model is named,
  and a named model must be served by its single credential.

<a id="concept-adr-0039-consequences"></a>
### Observable Consequences

Technical depth: [Adapters and proofs](0039-ephemeral-embedded-profile-technical.md#technical-adr-0039-proofs).

- **Embedding.** An Elixir host that depends on `loopex_composition` calls:
  - `LoopexComposition.Ephemeral.run/2` for one answer;
  - `start_session/1`, `ask/3`, `history/1` and `stop_session/1` for a
    conversation.

  It needs no state root, no companion build and no store setup.
- **Shells and agents.** They run `loopex ask "…"`, or `loopex -p "…"`, with
  `--model`, `--output json|text`, `--skill <dir>` and a named policy. The exit
  status reports the run's outcome, not only whether the command started.
- **Operators.** Nothing changes for them. `--state-root` on `ask`, or the
  durable composition in the API, selects today's behaviour exactly.
- **Profile visibility.** A session always states which profile it ran under,
  and an ephemeral session appears in no durable listing.

<a id="concept-adr-0039-compatibility"></a>
### Compatibility and Rollback

Technical depth: [Compatibility mechanics](0039-ephemeral-embedded-profile-technical.md#technical-adr-0039-compatibility).

This is additive:
- **Unchanged:** the durable profile, the public session protocol, the store
  format, the executor protocol, the daemon and core's runtime library.
- **Experimental** under the 0.x policy: the embedded API and the `ask` command.
- **New edge modules behind unchanged ports:** the memory store and the
  in-process adapter. Core's dependency budget is unchanged.
- **Rollback:** remove the profile. No durable byte depends on it.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
