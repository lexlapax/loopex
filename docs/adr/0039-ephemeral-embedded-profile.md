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
  - It supersedes one clause of
    [ADR 0025](0025-resource-packs-and-skill-admission.md#concept): admitted
    skill content no longer has to come only from the project's
    `.agents/skills/<name>` in an operator-selected Git directory at an exact
    commit. A caller may also name a skill directory outside the workspace,
    such as `~/.agents/skills/<name>`, admitted under its own truthful
    `user:<name>` identity. ADR 0025's admission record, the separation between
    admission and activation, the limit of four selected skills and project
    discovery's prompt are unchanged.
  - All three accepted records stay byte-for-byte as accepted. For every
    durable and daemon composition they govern exactly as before.
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
     and the runtime holds only a reference to that provider's credential,
     which a credential custodian resolves just before each call;
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

**Credential rule for the ephemeral profile.** It follows the vision's
credential contract: Loopex holds references, the host owns custody, and
resolution happens just in time at the model boundary.
- **Custody:** each ephemeral runtime has one credential custodian, a process
  the host owns through composition. The host supplies its resolver; the
  default resolver reads the provider's own environment variable when asked.
  The custodian keeps no value between calls.
- **Reference only in runtime state:** the runtime's model configuration
  carries the custodian and an opaque credential reference, never a value. No
  runtime, coordinator, guard or status term ever holds the key.
- **Resolution:** the adapter's provider call asks the custodian immediately
  before dispatch, uses the value for that one call, and drops it when the call
  ends. ReqLLM's own ambient key lookup is never used.
- **Structural exclusion:** the value never enters a journal record, a public
  event, progress, a diagnostic, a trace, a log line Loopex emits, a fixture or
  an executor job. For the life of an ephemeral runtime, one named primary
  logger filter removes any log event, crash reports included, that contains a
  value the custodian has resolved and not yet released. That covers ReqLLM's
  own processes, which hold the key while a call is in flight. Crash dumps
  remain the host's VM configuration, as the vision's list excludes them.
- **No key needed:** a provider that needs none, such as a local Ollama server,
  resolves none.
- **Missing key:** a provider whose credential cannot be resolved refuses at
  composition, naming the reference and never a value, and again before
  dispatch if it has since disappeared.
- **Tool processes:** the local executor removes every provider credential name
  from each tool process's environment, not only `LOOPEX_PROVIDER_API_KEY`.
- **What the durable profile adds:** process isolation through the companion.
  The ephemeral profile states plainly that it does not have it: the value is
  in the host VM's memory for the duration of each call.

**Host hygiene for the ephemeral profile.** The adapter runs inside a host that
may do other things, and ReqLLM loads a `.env` file when its application starts.
So Loopex, not the OTP application graph, starts ReqLLM:
- no Loopex application lists ReqLLM for automatic start, so it cannot start
  before hygiene is in place;
- composition turns off ReqLLM's automatic `.env` loading and its
  unverified-model warning, then starts ReqLLM itself;
- if ReqLLM is already running, composition refuses unless the host declares it
  started ReqLLM itself and ReqLLM's `.env` loading is already off.

The settings are VM-global and stay for the life of the VM, because ReqLLM
reads them only at its start; that is named, not restored. Every model is named
inline, so no model catalog is consulted.

**Skills named by path.** The ephemeral profile admits exactly the skill
directories its caller names. The rules:
- **No discovery.** It walks no directory on its own, so a headless caller is
  never prompted.
- **Two kinds of directory.** A directory at `.agents/skills/<name>` inside the
  workspace is a project skill, `project:<name>`, the identity discovery
  already gives. A directory outside the workspace, such as
  `~/.agents/skills/<name>`, is a user skill, `user:<name>`, bound to the
  content digest recorded when it is admitted. Any other directory inside the
  workspace refuses, because it is neither.
- **Local wins.** When a project skill and a user skill share a name, the
  project skill is admitted and the user skill is recorded as shadowed, not
  admitted.
- **Naming a directory is the host's admission decision.** It is recorded as
  ADR 0025's admission decision with `decision_source` `host_supplied`,
  `trust_scope` `project_skills` (the scope of skills admitted for this
  workspace's session), and the workspace binding. The host path is never
  recorded.
- **Admitted, then each activated,** so ADR 0025's separation between admission
  and activation holds, and its limit of four selected skills applies.

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
   ReqLLM supervision.** The ephemeral profile makes exactly two named changes
   and no others:
   - **One logger filter.** While an ephemeral runtime runs, it installs one
     primary logger filter with a fixed Loopex id, which removes only events
     that contain a credential value the custodian currently holds. It passes
     every other event unchanged, and the last ephemeral runtime to stop
     removes it. It installs no handler and changes no level.
   - **ReqLLM's start.** It sets automatic `.env` loading and the
     unverified-model warning off, then starts ReqLLM, as the host-hygiene rule
     states.

   It touches no group leader and never restarts ReqLLM's supervision tree. The
   adapter's provider call sets only its own process's logger level.
2. **ReqLLM's asynchronous diagnostics cannot be proved delivered or clean.**
   ReqLLM's own failure paths can log inspected reasons, crash reports from its
   stream and connection processes can carry request state, and a VM crash dump
   can hold anything.
   - The value filter excludes the known credential from every logged event,
     crash reports included, in both the library and the command.
   - The adapter's witness drives each path with a canary credential and
     requires the canary's absence from every committed plane, from the
     stream-start line, and from every captured log event, crash reports
     included, under both a library host's default logger and `ask`.
   - Crash dumps are VM configuration. The reference `ask` command disables
     them; a library host is told in the developer guide that a crash dump can
     hold any in-flight value.
   - Request data other than the credential, such as prompts and tool output,
     can still reach the host's logger through ReqLLM's failure paths. That
     output belongs to the host, and the developer guide says so.
3. **`LOOPEX_PROVIDER_API_KEY` is the only credential source.** In the ephemeral
   profile the host's custodian resolves each provider's own credential just in
   time. The durable profile keeps the single source.

What the ephemeral profile gives up is process isolation for the credential
while a call is in flight, and for provider diagnostics other than the
credential. That trade is the point of the profile, and it is stated wherever
the profile is offered.

**The `ask` command's machine contract.** Other agents and scripts parse it, so
it belongs to this decision as an experimental surface:
- **JSON:** `--output json` writes exactly one JSON object, schema
  `loopex.ask/1`, with a closed set of members. It carries the session and run
  ids, the profile, the outcome, the final text, each tool's id and outcome,
  any shadowed skill names, and a `details` object whose members are fixed per
  outcome. A `run.finished` field that is not in that set is not emitted, and
  every string and list has a stated bound.
- **Exit status:** `0` completed; `1` refused before the run; `2` failed; `3`
  bound reached; `4` outcome unknown; `5` cancelled; `6` no ending within the
  wait; `130` the existing interrupt. The values avoid the daemon's 65–111 and
  the launcher's 127.
- **Versioning:** a change to either, including a new member, is a new schema
  name under the 0.x policy.

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
  - `start_session/1`, `ask/3`, `answer/3`, `last_result/1`, `history/1` and
    `stop_session/1` for a
    conversation.

  It needs no state root, no companion build and no store setup. When stopping
  cannot prove that every provider and tool process has ended,
  `stop_session/1` returns an error, keeps the temporary root and names it,
  rather than deleting what an in-flight effect might still use.
- **Shells and agents.** They run `loopex ask "…"`, or `loopex -p "…"`, with
  `--model`, `--output json|text`, `--skill-dir DIR` (at most four, project or
  user skill directories) and a named policy. The exit status reports the run's
  outcome, not only whether the command started.
- **Operators.** Nothing changes for them. `--state-root` on `ask`, or the
  durable composition in the API, selects today's behaviour exactly.
- **Profile visibility.** The embedded API's session value and result, and
  `ask`'s JSON, carry the profile, and an ephemeral session appears in no
  durable listing.

<a id="concept-adr-0039-compatibility"></a>
### Compatibility and Rollback

Technical depth: [Compatibility mechanics](0039-ephemeral-embedded-profile-technical.md#technical-adr-0039-compatibility).

This is additive:
- **Unchanged:** the durable profile, the public session protocol, the store
  format, the executor protocol, the daemon and core's runtime library.
- **Experimental** under the 0.x policy:
  - the embedded API;
  - the `ask` command;
  - `ResourcePacks.read_directories/2`;
  - the durable composition's optional model, bounds, sampling and active-tool
    options, whose defaults reproduce M5.
- **New edge modules behind unchanged ports:** the memory store, the
  in-process adapter and the credential custodian. Core's dependency budget is
  unchanged.
- **Durable policy revision:** the durable composition's default policy
  identity keeps the revision it had in `0.2`, fixed rather than derived from
  the release version, so a pending interaction recorded under either release
  recovers under the other.
- **Rollback:** remove the profile. No durable byte depends on it, and a `0.2`
  binary opens and resumes every root `0.3` writes, pending interactions
  included.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
