<a id="concept"></a>
## Concept

Technical depth: [Profile composition, adapters and proofs](0039-ephemeral-embedded-profile-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-09-26
- **Decision owner:** Maintainer
- **Supersedes:** in part.
  - It scopes both rules of
    [ADR 0019](0019-host-owned-provider-protection.md#concept) to the durable
    profile: every provider invocation in a separate provider BEAM, and
    `LOOPEX_PROVIDER_API_KEY` as the only credential source. 0019's technical
    companion says restoring shared-VM provider handling "requires a new
    decision"; this is that decision, for the ephemeral profile only.
  - It scopes
    [ADR 0034](0034-provider-credential-handoff-over-bootstrap-channel.md#concept)'s
    companion custody and bootstrap handoff to the durable profile, where they
    govern exactly as before.
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
  - All three accepted records stay byte-for-byte as accepted.
- **Amends the vision:** §12's credential exclusion, for this profile only, as
  [the vision amendment](#concept-adr-0039-vision) below states.
- **Prerequisite for:** M6 outcomes 1 to 5, accepted with its paired vision
  amendment before the in-process model adapter, the memory store, the
  ephemeral composition, user skill directories or the fixed policy revision
  is written

<a id="concept-adr-0039-decision"></a>
### Context and Decision

Technical depth: [Profile composition](0039-ephemeral-embedded-profile-technical.md#technical-adr-0039-decision).

Technical depth: [The per-call process](0039-ephemeral-embedded-profile-technical.md#technical-adr-0039-tree).

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
     ReqLLM inside the host's VM for every provider the profile serves: a local
     Ollama server, and the hosted providers OpenAI, Anthropic and OpenRouter.
     A `provider:model` string selects the model;
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

**Credential rule for the ephemeral profile.** It keeps every part of the
vision's credential contract except one, which the vision amendment below
narrows:
- **A reference in runtime state.** The runtime's model configuration names
  the provider's credential variable, never its value.
- **Resolution at the model boundary.** The one process that makes the
  provider call reads that variable immediately before the call and passes the
  value to ReqLLM for that call only. The host supplies the value through its
  environment and owns it there.
- **Kept out of Loopex's planes.** The value never enters a journal record, a
  public event, progress, a diagnostic, a log line Loopex emits, a fixture or
  an executor job. The calling process is excluded from Loopex trace sessions
  and marked sensitive, so tracing, process inspection and crash-dump stacks
  do not show it.
- **Not structurally excluded from the host VM.** During a call, and until the call's connection closes when its response ends,
  the value is also held in the calling process's copies, in Finch's pool and
  in the TLS connection processes that carry the request, so their crash
  reports, a crash dump or a telemetry handler the host installs can see it.
  Every request asks the server to close its connection when the response
  ends, so the connection's TLS processes, and the key they copied, end with
  the call instead of waiting idle in the pool. That is the trade this profile
  makes, and the durable profile does not.
- **No key needed:** a provider that needs none, such as a local Ollama server,
  reads none.
- **Missing key:** a provider whose variable is missing or empty refuses at
  composition, naming the variable and never a value, and again before
  dispatch if it has since disappeared.
- **Tool processes:** the local executor removes every provider credential
  variable from each tool process's environment, not only
  `LOOPEX_PROVIDER_API_KEY`.

**Guards on each call.** The provider call runs inside a host VM whose global
configuration Loopex does not own, so the adapter refuses to call when that
configuration could change what the call does or where it goes:
- **Built-in providers only.** Before each call it checks that ReqLLM's
  registered module for the provider is ReqLLM's own, so a provider registered
  later under the same name cannot take the call.
- **No TLS key log.** Finch writes every TLS session's secrets to the file an
  `SSLKEYLOGFILE` variable names, which with a packet capture would reveal the
  key long after the call. Composition and each call refuse while it is set.
- **No global Req defaults.** Req merges `:req`'s default options, plugins
  included, into every request. Composition refuses, and each call refuses
  before dispatch, while any are set, so a global authentication header, cache,
  plugin, pool or transport cannot enter the call.
- **A connection pool with Loopex's fixed options.** Each call names a
  connection pool whose options Loopex fixes, so neither ReqLLM's shared pool
  nor anything the host configured for it, a proxy, a protocol or a pool
  started earlier, can carry the call. The pool lives under Req's supervisor
  and is shared by any caller using the same options; host code that
  deliberately registers a pool under its name first is trusted host code,
  which Loopex does not defend against. Each connection carries one call at a
  time, and the calling process itself drives the request, so a killed call
  stops sending at once.
- **HTTP/1 only, for now.** Every call uses HTTP/1, ReqLLM's own default. Both
  ways of using HTTP/2 through the locked Finch are unsafe for this adapter:
  its multiplexed pool can silently resend a request whose connection closes
  mid-upload, and HTTP/2 negotiated on its HTTP/1 pool ignores flow control,
  so any request over 64 KiB fails on a fresh connection. HTTP/2 is future
  work, for when Finch removes one of those limits.
- **Pinned address and options.** Each call names its address explicitly: the
  host's base URL, or the provider's built-in default, never one taken from
  ReqLLM's application configuration or model catalog. It allows no retry and
  follows no redirect, passes no response cache, and calls ReqLLM without its
  task-based timeout, so the request is made once, to that address, from the
  calling process.

**Cleanup owns what can return a result.** Each call has one cleanup owner that
stays responsive throughout, and one calling process that alone can return a
result to Loopex. The calling process catches every failure and ends with a
fixed reason, and the owner, also marked sensitive, reads only the shape of any
exit it sees, so no exception carrying the request or its credential reaches
the owner or anything it reports. On a stop or a deadline the owner kills that process; on
completion it exits by itself; either way the owner acknowledges cleanup, or
returns the reply, only after it has seen that process exit. If it cannot see
that, the kernel's existing unproved-cleanup path applies. The connection and
TLS processes that carried the request belong to the shared pool, not to the
call, but the calling process does the sending itself: when it dies it sends
nothing more, and its connection closes, either with it or when the pool sees
it gone. Bytes it
had already handed to the operating system may still leave, which changes
nothing, because the call is already `dispatched_or_unknown` and nothing can
reach the session.
The model's reply arrives whole: an in-process call reports no streamed
progress, which is transient and never session truth.

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
not restored; that is named. Every model is named inline, so no model catalog
is consulted and no unverified-model warning arises, and Loopex changes no
other ReqLLM setting.

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
  so a session with a user skill that is later resumed through the daemon
  cannot match its admitted snapshot, and resumes with all of its skill
  context withheld, project skills included, rather than silently replaced. The
  offline `loopex resume` restores it.

**Authority rule.** Neither profile has a default host authority. The caller
always names the policy:
- **In the API:** a module implementing `Loopex.Policy`. Composition ships no
  policy of its own, because host policy belongs to the host.
- **On the command line:** `--policy allow-all|shell-allowlist|refuse-all`,
  which the reference CLI maps to its own policy modules.

<a id="concept-adr-0039-relation-0019"></a>
### What Changes Relative to ADR 0019

Technical depth: [Shared-state and diagnostic facts](0039-ephemeral-embedded-profile-technical.md#technical-adr-0039-relation-0019).

ADR 0019 moved the provider out of the host VM for three reasons. The ephemeral
profile answers each one as follows.

1. **An adapter must not change the host's logger, group leaders or shared
   ReqLLM supervision.** The in-process adapter installs no logger filter or
   handler, changes no primary level and touches no group leader. Its one named
   change to shared state is ReqLLM's start and its `.env` setting, under the
   host-hygiene rule. Each call's own process silences its own logging.
2. **ReqLLM's asynchronous diagnostics cannot be proved delivered or clean.**
   They can carry the request, and for a hosted provider its credential, into
   the host's logger, crash reports, crash dumps and telemetry handlers, which
   the host owns. The vision amendment accepts that for this profile. The
   developer guide tells a library host what it takes on, and the `ask` command
   turns its own logger off and disables crash dumps.
3. **`LOOPEX_PROVIDER_API_KEY` is the only credential source.** In the
   ephemeral profile each hosted provider has its own variable, read at the
   model boundary for each call. The durable profile keeps the single source.

What the ephemeral profile gives up is process isolation for the credential and
the request during a call, until the call's connection closes when its response ends. That trade is the point of the profile,
and it is stated wherever the profile is offered.

**The `ask` command's machine contract.** Other agents and scripts parse it, so
it belongs to this decision as an experimental surface:
- **JSON:** `--output json` writes exactly one JSON object and nothing else on
  standard output. Its members are exactly:
  - `schema`, always `loopex.ask/1`;
  - `session_id`, `run_id`, `profile` and `outcome`;
  - `text` and `text_truncated`;
  - `tools`, each with its tool id and outcome, and `tools_truncated`;
  - `shadowed_skills`;
  - `cleanup`: for the ephemeral profile, whether stopping proved that the
    session's tool processes and every process that could return a provider
    result had ended, and if not, the kept temporary root and what remained
    unproved; `null` for the durable profile, which keeps its session running;
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

**Model selection.** A `provider:model` string selects the model:
`ollama:<model>`, `openai:<model>`, `anthropic:<model>` or
`openrouter:<model>`.
- **Ephemeral profile:** the in-process adapter serves all four. When none is
  given, it uses `LOOPEX_MODEL`, and then the local default `ollama:llama3.2`,
  so the profile works with no key and no companion.
- **Durable profile:** the companion serves every model. It keeps its pinned
  reference model unless a model is named, and a named model must be served by
  its single credential. An `ollama:` model is refused there in M6, because
  the companion requires a credential.

<a id="concept-adr-0039-vision"></a>
### The Vision Amendment

Technical depth: [Amended text and mechanics](0039-ephemeral-embedded-profile-technical.md#technical-adr-0039-vision).

This decision amends the vision's credential rule, and the paired vision files
change with its acceptance:

- **Principle changed.** The vision's technical §12.7 excludes known
  credentials from crash reports, its §6.2 counts crash detail and traces as
  the diagnostics plane, its §16 says observability never captures secrets, its
  §23 verification rule says known credential material never appears in a
  prohibited plane, and AGENTS.md repeats the exclusion as a non-negotiable.
  For a profile the host explicitly composes to run the provider library in its
  own VM, a credential may be present in that library's processes during a
  call, until the call's connection closes when its response ends; so in their crash reports, a crash dump or a
  host telemetry handler. §12.7's "narrowest possible lifetime and audience"
  also yields there: the host supplies the value through its environment,
  which any code in its VM can read. Every other exclusion stands, and the
  reference in runtime state, resolution at the model boundary and host
  custody stand.
- **Host resolution.** Vision §6.1 gives the host credential resolution. Here
  the host resolves by placing the value in a variable it names in its own
  environment; the adapter reads that host-supplied value at the model
  boundary, as the vision's "resolution occurs just in time at the approved
  model boundary" allows, and Loopex stores only the variable's name.
- **Where it lands.** Seven places gain the same bounded exception, in the
  exact text ADR 0039's technical companion gives, in the change that accepts
  this decision: `docs/vision.md` §12 and §16; `docs/vision-technical.md`
  §6.1, §6.2, §12.7 and §23; and AGENTS.md's "Credentials and context"
  non-negotiable, which needs the maintainer's explicit approval.
- **Evidence.** Five external reviews of this decision tried to keep a
  credential structurally out of an in-VM ReqLLM call: a custodian with a
  value-redacting logger filter (the filter's readable value set, its
  contiguous-match limit and its release before ReqLLM's processes ended), then
  a credential-free in-VM path beside the companion (ReqLLM's Task and
  metadata processes, Req defaults, redirects and pool changes that carry a
  request out of the caller). Each exposed a path through the host's global
  configuration or ReqLLM's process structure that Loopex does not own. The maintainer chose one in-VM ReqLLM path for every
  provider in the ephemeral profile over carrying the companion into it.
- **Compatibility impact.** None for existing users. The durable profile, the
  daemon and every accepted credential decision keep full isolation. The
  exception applies only where a host composes the ephemeral profile with a
  hosted model.
- **Migration path.** A host that needs structural exclusion composes the
  durable profile, or keeps to a credential-free local model in the ephemeral
  one. A later decision may add a companion path to the ephemeral profile.

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

  It needs no state root, no companion build and no store setup; a hosted
  model needs its provider's credential variable. When stopping cannot prove
  that the session's tool processes and every process that could return a
  provider result have ended, `stop_session/1` returns an error, keeps the
  temporary root and names it, rather than deleting what an in-flight effect
  might still use.
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
- **Amended:** the vision's §12 credential exclusion, for the ephemeral profile
  only.
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
  - a call to a tool only `0.3` defines, such as `grep`, that was not yet
    dispatched when the root is resumed under `0.2`: the call is committed as a
    failed `unknown_tool` call and the run continues. One already dispatched
    follows core's dispatched-effect recovery unchanged: `0.2` queries the
    executor, admits a matching receipt, and otherwise leaves the work pending
    for reconciliation; it is never run again;
  - a user skill admitted under `0.3`: its snapshot is retained under the
    state root by digest like any admitted pack's. `0.2`'s offline
    `loopex resume` reloads it by that digest, because its validation already
    accepts the `user:<name>` identity. `0.2`'s daemon, which composes only the
    workspace's discovered project skills, resumes the session with all of its
    skill context withheld, project skills included, as core does for any
    snapshot it cannot match.
    `0.2` cannot admit a new one.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
