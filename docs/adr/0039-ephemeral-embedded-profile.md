<a id="concept"></a>
## Concept

Technical depth: [Profile composition, adapters and proofs](0039-ephemeral-embedded-profile-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-26
- **Decision owner:** Maintainer
- **Supersedes:** in part.
  - It narrows one rule of
    [ADR 0019](0019-host-owned-provider-protection.md#concept): every provider
    invocation runs in a separate provider BEAM, except a call to a provider
    that needs no credential in the ephemeral profile. 0019's technical
    companion says restoring shared-VM provider handling "requires a new
    decision"; this is that decision, for credential-free providers in the
    ephemeral profile only. The durable profile uses the companion for every
    model, exactly as before. 0019's other rule, `LOOPEX_PROVIDER_API_KEY` as
    the only credential source, is unchanged in both profiles.
  - It supersedes two clauses of
    [ADR 0025](0025-resource-packs-and-skill-admission.md#concept), in both
    profiles:
    - **Source.** Admitted skill content no longer has to come only from the
      project's `.agents/skills/<name>`: a caller may also name a skill
      directory outside the workspace, such as `~/.agents/skills/<name>`,
      admitted as a user skill under its own `user:<name>` identity. 0025's
      exclusion of configured or home roots is lifted for directories a caller
      names, and only for them.
    - **Name order.** 0025 refuses an ambiguous unqualified name and grants no
      search order. Among the directories a caller names, a project skill now
      takes precedence over a user skill of the same name, and the user skill
      is reported as shadowed and never enters the manifest.

    0025's admission record, the separation between admission and activation,
    the limit of four selected skills, Git-sourced installation and project
    discovery's prompt are unchanged.
  - [ADR 0034](0034-provider-credential-handoff-over-bootstrap-channel.md#concept)
    is unchanged: every call that needs a credential, in either profile, uses
    the companion and its bootstrap-channel handoff.
  - All three accepted records stay byte-for-byte as accepted.
- **Prerequisite for:** M6 outcomes 1 to 5, accepted before the in-process
  model adapter, the memory store, the ephemeral composition, user skill
  directories or the fixed policy revision is written

<a id="concept-adr-0039-decision"></a>
### Context and Decision

Technical depth: [Profile composition](0039-ephemeral-embedded-profile-technical.md#technical-adr-0039-decision).

Technical depth: [The per-call process tree](0039-ephemeral-embedded-profile-technical.md#technical-adr-0039-tree).

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
   - **a model adapter chosen by credential.** A `provider:model` string selects
     the model:
     - a provider that needs no credential, a local Ollama server in M6, runs
       through a new in-process adapter inside the host's VM;
     - a provider that needs one runs through the existing companion adapter,
       exactly as the durable profile does: a separate provider BEAM, the single
       `LOOPEX_PROVIDER_API_KEY` in ADR 0034's host custody and handed off over
       the bootstrap channel, and the built companion the host names;
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

**Credential rule.** The ephemeral profile adds no new credential path:
- **In-process calls carry no credential.** The in-process adapter serves only
  providers that need none. It never reads a credential, never passes a key to
  ReqLLM, and refuses a credential-bearing provider before calling ReqLLM. No
  credential enters an ephemeral runtime's state or an in-process request.
- **Credential-bearing calls use the accepted path unchanged.** They go
  through the companion under ADR 0034, whose host custody, bootstrap handoff
  and trace exclusion apply exactly as in the durable profile.
- **The host's environment is the host's.** An embedding host that has
  `LOOPEX_PROVIDER_API_KEY` in its environment and composes only an Ollama
  model keeps it there untouched: the library consumes it, reading and removing
  it as the durable composition already does, only when it opens the companion
  path. The `ask` command, which owns its own VM, discards it unread when it
  selects an Ollama model.

**Each in-process call is one process.** The in-process adapter makes a
non-streaming call that ReqLLM, Req and Finch perform entirely inside the one
process that asks for it, so no other process ever holds that call's request.
Each call has a cleanup owner that stays responsive throughout. On a stop, a
deadline or completion it ends that process and acknowledges cleanup only after
it has seen it exit. If it cannot see that, the kernel's existing
unproved-cleanup path applies. The model's reply arrives whole: an in-process
call reports no streamed progress, which is transient and never session truth.

**Host hygiene.** The in-process adapter runs inside a host that may do other
things, and ReqLLM loads a `.env` file when its application starts. So Loopex,
not the OTP application graph, starts ReqLLM:
- no Loopex application lists ReqLLM for automatic start, so it cannot start
  before hygiene is in place;
- before starting ReqLLM, composition turns off its automatic `.env` loading
  as a persistent setting that no application load overwrites, and records
  that Loopex made it;
- a composition proceeds whenever ReqLLM is running with `.env` loading off and
  either that record exists or the host declares that it started ReqLLM itself
  that way;
- a ReqLLM running with `.env` loading on, or started by the host undeclared,
  is refused.

Because the setting persists, a later stop and restart of ReqLLM also loads no
`.env`, unless the host deliberately turns loading back on, which the next
composition sees and refuses. The setting stays for the life of the VM and is
not restored; that is named. Every in-process model is named inline, so no
model catalog is consulted and no unverified-model warning arises, and Loopex
changes no other ReqLLM setting.

**Skills named by path.** Both profiles admit exactly the skill directories
their caller names, beside the durable profile's existing installed and
discovered skills. The rules:
- **No discovery.** The ephemeral profile walks no directory on its own, so a
  headless caller is never prompted.
- **Two kinds of directory.** Classified against the workspace root:
  - a directory at `.agents/skills/<name>` inside the workspace is a project
    skill, `project:<name>`, the identity discovery already gives;
  - a directory outside the workspace, such as `~/.agents/skills/<name>`, is a
    user skill, `user:<name>`, bound to the content digest recorded when it is
    admitted;
  - any other directory inside the workspace refuses, because it is neither.
- **Local wins.** When a project skill and a user skill share a name, the
  project skill is admitted and the user skill is reported as shadowed.
- **Naming a directory is the host's admission decision.** It is recorded as
  ADR 0025's admission decision with `decision_source` `host_supplied`,
  `trust_scope` `project_skills` (the scope of skills admitted for this
  workspace's session), and the workspace binding. The host path is never
  recorded.
- **Admitted, then each activated,** so ADR 0025's separation between admission
  and activation holds, and its limit of four selected skills applies. In the
  durable profile the admitted snapshot is retained under the state root and
  the admission journaled, like any admitted pack's.
- **Where the durable profile takes them.** Named skill directories enter a
  durable session through the durable composition's API and `ask --state-root`,
  and the offline `loopex resume` reloads them by digest. The daemon is
  unchanged in M6: it composes only the workspace's discovered project skills,
  so a session with a user skill that is later resumed through the daemon has
  that skill's context withheld rather than silently replaced.

**Authority rule.** Neither profile has a default host authority. The caller
always names the policy:
- **In the API:** a module implementing `Loopex.Policy`. Composition ships no
  policy of its own, because host policy belongs to the host.
- **On the command line:** `--policy allow-all|shell-allowlist|refuse-all`,
  which the reference CLI maps to its own policy modules.

<a id="concept-adr-0039-relation-0019"></a>
### What Changes Relative to ADR 0019

Technical depth: [Shared-state and diagnostic facts](0039-ephemeral-embedded-profile-technical.md#technical-adr-0039-relation-0019).

ADR 0019 moved the provider out of the host VM for three reasons. For a
credential-free call in the ephemeral profile they are answered as follows.

1. **An adapter must not change the host's logger, group leaders or shared
   ReqLLM supervision.** The in-process adapter installs no logger filter or
   handler, changes no primary level and touches no group leader. Its one named
   change to shared state is ReqLLM's start and its `.env` setting, under the
   host-hygiene rule. Each call's own process silences its own logging.
2. **ReqLLM's asynchronous diagnostics cannot be proved delivered or clean.**
   With no credential in the in-process request, what those diagnostics can carry is request
   data: prompts, tool output and the model's reply, which the host supplied or
   the host's own session produced. It can reach the host's logger and crash
   dumps, which the host owns. The developer guide says so, and the `ask`
   command turns its own logger off and disables crash dumps.
3. **`LOOPEX_PROVIDER_API_KEY` is the only credential source.** Unchanged.

What the ephemeral profile gives up, for credential-free calls only, is process
isolation for request data and for provider diagnostics. That trade is stated
wherever the profile is offered.

**The `ask` command's machine contract.** Other agents and scripts parse it, so
it belongs to this decision as an experimental surface:
- **JSON:** `--output json` writes exactly one JSON object and nothing else on
  standard output. Its members are exactly:
  - `schema`, always `loopex.ask/1`;
  - `session_id`, `run_id`, `profile` and `outcome`;
  - `text` and `text_truncated`;
  - `tools`, each with its tool id and outcome, and `tools_truncated`;
  - `shadowed_skills`;
  - `cleanup`: whether stopping proved that every provider and tool process of
    the session had ended, and if not, the kept temporary root and what
    remained unproved;
  - `details`, whose members are fixed per outcome.

  A `run.finished` field outside that set is not emitted. Every string and
  list has a stated bound, and a longer answer or tool list is cut and flagged.
  A refusal before the run writes nothing to standard output.
- **Exit status:** `0` completed; `1` refused before the run; `2` failed; `3`
  bound reached; `4` outcome unknown; `5` cancelled; `6` no ending within the
  wait; `130` the existing interrupt. The values avoid the daemon's 65–111 and
  the launcher's 127. An unproved cleanup does not change the status; it is
  reported in `cleanup` and on standard error.
- **Versioning:** a change to either, including a new member, is a new schema
  name under the 0.x policy.

**Model selection.** A `provider:model` string selects the model.
- **Ephemeral profile:** the in-process adapter serves `ollama:<model>`; any
  other provider the companion serves goes through the companion. When none is
  given, it uses `LOOPEX_MODEL`, and then the local default `ollama:llama3.2`,
  so the profile works with no key and no companion.
- **Durable profile:** the companion serves every model. It keeps its pinned
  reference model unless a model is named, and a named model must be served by
  its single credential. An `ollama:` model is refused there in M6, because
  the durable profile has no in-process adapter.

<a id="concept-adr-0039-consequences"></a>
### Observable Consequences

Technical depth: [Adapters and proofs](0039-ephemeral-embedded-profile-technical.md#technical-adr-0039-proofs).

- **Embedding.** An Elixir host that depends on `loopex_composition` calls:
  - `LoopexComposition.Ephemeral.run/2` for one answer;
  - `start_session/1`, `ask/3`, `answer/3`, `last_result/1`, `history/1` and
    `stop_session/1` for a conversation. The session value is an opaque in-VM
    handle the host passes back and never inspects, like a runtime reference;
    what the host may read comes back in the result, which carries the session
    id and the profile.

  With a local model it needs no state root, no companion build, no credential
  and no store setup. A hosted model needs what the companion always needs: the
  built companion and `LOOPEX_PROVIDER_API_KEY`. When stopping cannot prove
  that every provider and tool process has ended, `stop_session/1` returns an
  error, keeps the temporary root and names it, rather than deleting what an
  in-flight effect might still use.
- **Shells and agents.** They run `loopex ask "…"`, or `loopex -p "…"`, with
  `--model`, `--output json|text`, `--skill-dir DIR` (at most four, project or
  user skill directories) and a named policy. The exit status reports the run's
  outcome, not only whether the command started.
- **Operators.** `--state-root` on `ask`, or the durable composition in the
  API, selects today's behaviour, plus the named skill directories and the
  optional model, bound, sampling and active-tool options.
- **Profile visibility.** The embedded API's session value and result, and
  `ask`'s JSON, carry the profile, and an ephemeral session appears in no
  durable listing.

<a id="concept-adr-0039-compatibility"></a>
### Compatibility and Rollback

Technical depth: [Compatibility mechanics](0039-ephemeral-embedded-profile-technical.md#technical-adr-0039-compatibility).

This is additive:
- **Unchanged:** the public session protocol, the store format, the executor
  protocol, the daemon, the companion and core's runtime library.
- **Experimental** under the 0.x policy:
  - the embedded API;
  - the `ask` command;
  - `ResourcePacks.read_directories/2`;
  - the durable composition's optional model, bounds, sampling and active-tool
    options, whose defaults reproduce M5.
- **New edge modules behind unchanged ports:** the memory store and the
  in-process adapter. Core's dependency budget is unchanged.
- **Durable policy revision:** the durable composition's default policy
  identity keeps the revision it had in `0.2`, fixed rather than derived from
  the release version, so a pending interaction recorded under either release
  recovers under the other.
- **Rollback** to `0.2`: remove the profile. No durable byte depends on it, and
  a `0.2` binary opens and resumes every root `0.3` writes, with two named
  exceptions that each leave a truthful record:
  - a call to a tool only `0.3` defines, such as `grep`, that is still pending
    when the root is resumed under `0.2`: the call is committed as a failed
    `unknown_tool` call and the run continues;
  - a user skill admitted under `0.3`: its snapshot is retained under the
    state root by digest like any admitted pack's. `0.2`'s offline
    `loopex resume` reloads it by that digest, because its validation already
    accepts the `user:<name>` identity. `0.2`'s daemon, which composes only the
    workspace's discovered project skills, resumes the session with that
    skill's context withheld, as core does for any snapshot it cannot match.
    `0.2` cannot admit a new one.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
