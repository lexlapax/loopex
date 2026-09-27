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
      is reported by its exact `user:<name>` source id as shadowed and never
      enters the manifest.

    0025's admission record, the separation between admission and activation,
    the limit of four selected skills, Git-sourced installation and project
    discovery's prompt are unchanged.
  - All three accepted records stay byte-for-byte as accepted.
- **Amends the vision:** clarifies §12 durability; amends the credential
  exclusion in Concept §12 and §16, Technical §6.1, §6.2, §12.7 and §23,
  and AGENTS.md, for this profile only, as
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

This selects the in-memory adapter that the technical vision §12.2 already
authorizes for "tests and simple embedding." Concept §12 is titled "Durable
sessions, context, and storage"; its survival promise governs a session Loopex
represents as durable, while the paired technical section explicitly names
this non-durable store posture. This ADR does not claim that durable history may
be volatile. The ephemeral profile uses the same session semantics and commit
ordering only for its declared runtime lifetime, never enters a durable listing
or root, never labels its state durable, and exposes no recovery surface.
Therefore its memory lifetime applies the paired vision's existing in-memory
case rather than amending the durable-session guarantee.

**Credential rule for the ephemeral profile.** It keeps every part of the
vision's credential contract except one, which the vision amendment below
narrows:
- **A reference in runtime state.** The runtime's model configuration names
  the provider's credential variable, never its value.
- **Resolution at the model boundary.** The one process that makes the
  provider call reads that variable immediately before the call and passes the
  value to ReqLLM for that call only. The value must be 1 to 65,536 bytes;
  absent, empty or larger values refuse before disclosure to ReqLLM. The host
  supplies the value through its environment and owns it there.
- **Kept out of Loopex-owned provider handling.** Loopex does not inject the
  selected model key into a journal record, public event, progress, diagnostic,
  log, fixture or executor job. The provider caller rejects its exact value
  before the mapped provider reply enters those planes. Host-authorized tools
  can independently read/disclose ambient values through their ordinary tool
  outputs; those disclosures are an explicit host-owned exception, not a
  secrecy guarantee this profile supplies. Before a mapped provider reply can leave the caller, every
  provider-controlled binary in it—including assistant text, tool-call fields
  and `provider_response_id`—is checked for the exact resolved value; a match
  discards the reply and returns a fixed failure. If a host-authorized tool
  put that key into model context, repeated provider echoes can keep failing as
  `model_call_failed` while the context remains. The guard has no tool-copy
  exemption and performs no context cleansing; proved failed-call cleanup does
  not itself seal the session. The host owns its tool/context choice. The calling process is
  excluded from Loopex trace sessions and marked sensitive, so Loopex tracing
  omits it and ordinary crash-dump process detail is suppressed.
- **Not structurally excluded from the host VM.** The host environment keeps
  the value for the lifetime and audience the host chooses. During a call the
  value is also present in the sensitive calling process, the call-owned HTTP
  connection and its TLS processes, and the arguments of provider-library
  telemetry handlers. Their crash reports, a crash dump or a handler the host
  installs can therefore observe it, and any copy a handler makes has the
  host's lifetime. Before returning a provider result or acknowledging a
  successful stop, Loopex proves the caller and tagged Finch pool subtree gone;
  it also disables TLS session reuse, session tickets and TLS secret retention.
  A checked-out socket and its OTP TLS controller are not children of that pool
  and may finish asynchronously after the caller and pool have ended. They have
  no route to the session, but bytes already handed to them may still leave.
  Under isolated release conditions the witness requires both gone within
  5,000 ms of caller `DOWN`; runtime cleanup does not wait for or prove that
  threshold. This proves the owned processes and result route gone, not
  synchronous transport-process closure or byte erasure from arbitrary host-VM
  memory. That is the trade this profile makes, and the durable profile does not.
- **No key needed.** Ollama reads no credential; its caller has the same
  per-call ownership and transport proof as a hosted caller.
- **Missing key.** Only the sensitive caller reads the selected hosted
  variable. A missing, empty or over-bound value refuses before ReqLLM;
  composition validates the reference, never the value.
- **Tools and host trust.** Hosted and local models may use either active tool
  preset. Ambient provider-key variables are permitted, and the existing local
  executor environment semantics remain unchanged. A tool or other trusted
  host-VM code may read, copy or disclose an ambient value; this profile does
  not isolate credentials from tools or other host code. The provider reply
  check still excludes the exact selected key from Loopex's mapped model
  result; it cannot classify arbitrary secrets a tool chooses to read. The
  host chooses workspace, policy, environment, telemetry and permitted tools.
  A host needing structural exclusion uses the durable profile or an isolated
  VM and hand.
- **Failure containment.** Cleanup uncertainty seals only the affected session
  against new model and tool work. Its root and process census remain for the
  bounded stop/retry contract. Successful proof marks that handle closed; it
  never reopens it. Other sessions keep their independent cells and pools.
  No VM-wide gate, credential/tool lease, quarantine or VM-restart lockout is
  part of this profile. Shared dependency loss can still interrupt sessions
  using that dependency; session containment is not shared-service availability.

**Maintainer decisions recorded 2026-09-27.** These approvals authorize the
following design choices; they do not accept ADR 0039 or the M6 plan pair:

| Choice | Decision and connotation |
| --- | --- |
| Provider path | Approved: non-streaming calls, per-call tagged HTTP/1 pools and the one-shot adapter. The unchanged core remains the deadline and effect-classification authority. |
| Hosted tools | Hosted ephemeral tools stay in scope. Both tool presets remain available for hosted and local models; the durable profile is an isolation choice, not a prerequisite for hosted tool use. |
| Ambient variables | Tools are allowed with ambient provider-key variables. Tool admission does not probe or scrub those variables, and the profile makes no secrecy guarantee against a policy-authorized tool reading them. |
| Cleanup containment | Cleanup failure is session-scoped, with no VM lockout. The affected handle admits no further effects and retains its unproved obligations; independent sessions remain usable. |

**Guards on each call.** The provider call runs inside a host VM whose global
configuration Loopex does not own, so the adapter refuses to call when that
configuration could change what the call does or where it goes:
- **Built-in providers only.** Before each call it checks that ReqLLM's
  registered module for the provider is ReqLLM's own, so a provider registered
  later under the same name cannot take the call.
- **No TLS key-log destination.** Finch treats `SSLKEYLOGFILE` as an
  environment-selected key-log destination. Composition and each call refuse
  while it is set, and the call's TLS options explicitly disable secret
  retention instead of depending on a particular OTP release to return no
  key-log data. When Loopex must start ReqLLM and Req, this guard runs before
  that start. If the host already started them, refusal prevents Loopex's
  call-owned pool from opening or appending to the destination; it cannot undo
  an earlier host-side file open.
- **No global Req defaults.** Req merges `:req`'s default options, plugins
  included, into every request. Composition refuses, and each call refuses
  before dispatch, while any are set, so a global authentication header, cache,
  plugin, pool or transport cannot enter the call.
- **One call-owned connection pool.** The cleanup owner gives each call an
  unguessable reference tag and starts one user-managed Finch pool under a
  supervisor it owns. The pool has one HTTP/1 connection slot and is never
  shared with another call. `Req.Finch` supplies only its VM-wide duplicate
  worker registry and unique pool-supervisor registry, in which that owned pool
  is registered; ReqLLM's pool and every shared default
  pool do not carry the request. The one-shot adapter calls the exact monitored
  HTTP/1 worker PID directly, so a missing or restarted tagged pool cannot make
  Finch auto-start a replacement or fall back to shared transport. The calling
  process drives the request. Its death makes NimblePool cancel and remove the
  checked-out connection resource; the HTTP/1 pool worker itself remains until
  the owner tears down the tagged pool. The result route ends with the caller,
  without relying on the server to close first. Bytes already handed to TLS or
  the operating system can still drain as described under cleanup.
- **HTTP/1 only, for now.** Every call uses HTTP/1, ReqLLM's own default. Both
  ways of using HTTP/2 through the locked Finch are unsafe for this adapter:
  its multiplexed pool can silently resend a request whose connection closes
  mid-upload, and HTTP/2 negotiated on its HTTP/1 pool ignores flow control,
  so any request over 64 KiB fails on a fresh connection. HTTP/2 is future
  work, for when Finch removes one of those limits.
- **Pinned address and one dispatch.** Each call names a normalized address
  explicitly: `https` for OpenAI, Anthropic and OpenRouter, and `http` or
  `https` for credential-free Ollama. It is the host's base URL or the
  provider's built-in default, never one taken from ReqLLM's application
  configuration or model catalog. User information, proxies and transport
  substitution are refused.
  A thin Req adapter validates the final request's origin and tagged pool,
  removes Loopex's private call context, and obtains one atomic dispatch grant
  and the exact monitored HTTP/1 worker from the cleanup owner. It builds the
  Finch request and invokes that worker directly once, without a pool-manager
  lookup. Every later invocation is refused before network activity. Redirects, ReqLLM
  retries and caching are also disabled, and ReqLLM's task-based timeout is not
  used.
- **Bounded response.** The Req adapter installs its own 8 MiB response
  collector before delegation. A larger fixed-length or chunked body halts the
  HTTP/1 request and records the private `model_response_too_large` sentinel.
  It requests identity encoding and records the private
  `model_response_encoding_unsupported` sentinel for an encoded response rather
  than risking unbounded decompression. Both become the public
  `model_call_failed` result.
- **Dependency-visible tool calls.** The shared response mapper validates the
  buffered `%ReqLLM.ToolCall{}` that locked ReqLLM exposes and accepts only a
  non-empty id and name with a binary JSON object decoded without repair.
  Invalid text, `null`, arrays, incomplete JSON and visible error metadata fail
  the whole started model call instead of becoming an empty-argument call. A
  call still marked by ReqLLM as provider-executed or provider-native also fails
  the whole call: those classes are not replayable application calls and never
  become a local core tool request.
  ReqLLM 1.24 has already normalized or discarded some provider-wire defects
  before that seam: it can generate a replacement for a missing id, turn missing, nil, empty or
  unsupported arguments into literal `{}`, force the function type, omit a
  malformed call and remove earlier error metadata. M6 treats the resulting
  `{}` or absent call as the dependency's buffered semantics; it does not claim
  to reconstruct those erased distinctions. An exposed `{}` still crosses
  ordinary tool resolution, schema validation and host policy before any
  effect.

The host is trusted code in the same VM. Code that deliberately changes
ReqLLM's registry, global configuration or the request after a guard can race
these checks; the final adapter closes every route it can validate, but this
profile is not a sandbox from its host.

**Cleanup owns the provider call.** The callback first acquires the kernel's
invocation-local child starter. An unmanaged invocation creates nothing and
returns fixed `not_dispatched`. A managed invocation starts one authority-free
candidate through a bounded, unlinked proxy. Before exact managed lifetime
registration it receives no session cell, request, option, credential, pool or
activation token. Only reconciled candidate/proxy identities, exact normal
proxy termination, managed core registration and the callback's one-use
activation release call authority.

An unknown queued start or missing candidate/proxy termination seals only the
attempted session and remains conservative failure; it never becomes clean
`not_dispatched`. A queued Task.Supervisor start may later materialize only an
inert candidate. Before `registration_pending` it exits on callback/proxy loss
or expiry. After acknowledging that phase it cancels its expiry and stays inert
on callback loss, awaiting core's exact stop or session-subtree teardown. In the
locked worker-retained/guard-unregistered interval,
core may settle before that authority-free candidate's termination; this
proves no registered provider-resource obligation or released authority, not
candidate termination. Complete session-subtree proof still reaps it. If
registration committed first, the missing stop handshake is unproved cleanup.

Each admitted call has a responsive, sensitive cleanup owner, one sensitive
caller and one request-free pool-lifecycle root with its tagged pool subtree.
The owner keeps identities, process census and a bounded mapped result; never
the key or raw request/error. The caller catches failures and reports only
fixed classes or an exact-key-checked mapped reply. After the one-shot direct
worker call returns, the adapter requests pool teardown while the caller
waits. The caller then maps its result; the owner ends and proves that caller
terminated before returning it. Pre-adapter refusal takes the same applicable
owned teardown. Stop/deadline first makes results inadmissible and ends the
caller, then requests pool teardown. Missing proof seals this session and
withholds success or a stop acknowledgement. The owner remains alive until
core's registered-resource stop handshake finishes. The model reply is whole;
there is no streamed progress.

M6 adds an opaque lifecycle cell for each session as its explicit private
admission seal: open `0`, stopping `1`, closed `2`, cleanup-unproved `3`.
A second private atomic slot is idle `0` or provider-attempt outstanding `1`.
Before any proxy/candidate, the callback requests begin-model custody from the
responsive session owner, which reserves that slot and records its reference/
monitor. Model and executor edges use inward private admission behaviours with
one composition implementation over that M6 owner; no new global actor
or secret-bearing message is introduced. No pre-registration child
receives the cell. Every model/tool grant requires open and a bounded correlated
session-owner reconciliation of any prior outstanding attempt. A managed call
clears outstanding only after the owner accepted its correlated clean-retirement
proof and observed exact registered-cleanup-owner DOWN; clean pre-registration
refusal requires its exact no-child/candidate/proxy proof instead. Missing proof
writes lifecycle `3`; lost notification cannot reopen or clear outstanding. Stop may move `1` or `3` to `2` only after proof,
never back to `0`. Previously granted effects retain their executor cleanup
obligations. Non-stop facade calls use the existing lifecycle-first refusal;
inspection survives only where the M6 API explicitly permits it.

**Host hygiene.** ReqLLM, Req and Finch are compile-time/code dependencies but
not automatically started runtime dependencies. Before an explicit start,
composition requires empty Req defaults, no `SSLKEYLOGFILE` and
`TIDEWAVE_REPL != "true"`. A temporary `ReqLLMStarter` service serializes
startup under M6's shared-start protocol. Its worker contains no session input,
key, activation or effect authority. A waiter has a 5,000 ms bound; timeout or
requester death does not cancel shared application-controller work. The
service retains startup provenance for later reconciliation; uncertainty is a
fixed startup refusal for that waiter, not a persistent poison or VM lockout.
Only a positively completed Loopex start establishes provenance. A service
crash is not automatically restarted and cannot consume the session parent's
restart budget; a later creation recreates it within its existing startup bound.
An admitted unlinked initializer survives service loss. An indeterminate
running application without positive provenance requires the host declaration,
not inferred ownership from a stale start intent.
Already-running ReqLLM is accepted only with .env loading off and retained
Loopex startup provenance or the host's explicit declaration. Shared-service
outages are reported honestly and may affect sessions using that service.

Loopex persists `load_dotenv: false` before its admitted ReqLLM start, including
overriding a stopped application's `load_dotenv: true`, and does
not restore the setting or stop reference-counted dependencies. The host owns
later mutations, false declarations, preexisting listener/file opens and
shared infrastructure. Inline models avoid catalog lookup; no other ReqLLM
setting changes. Embedded and escript startup use the same guards. The escript
uses `app: nil`: invalid ask forms start no Loopex application, valid
ephemeral forms call the bounded composition bootstrap, durable ask uses its
fixed-diagnostic start helper, and legacy commands preserve the former startup
and error behavior. Handle-consuming calls never bootstrap.

<a id="concept-adr-0039-public"></a>
### Public Admission and Packaging Contracts

Technical depth: [Admission and packaging mechanics](0039-ephemeral-embedded-profile-technical.md#technical-adr-0039-public).

| Contract | Observable rule |
| --- | --- |
| Base URL | At most 65,536 UTF-8 bytes: lowercase `https://host[:port][/path]` for hosted providers; Ollama also accepts `http`. Host is canonical IPv4 or ASCII DNS (253 bytes; 1..63-byte letter/digit-ended labels with internal hyphens), normalized lowercase. No IPv6, Unicode/percent-encoded host, userinfo, trailing DNS dot, query or fragment. Port is canonical decimal 1..65,535, with default 80/443 normalized away. Path uses slash-separated unreserved ASCII segments; no percent escapes, backslash, interior repeated separators or dot/dotdot segment; trailing slashes normalize away. |
| Composition precedence | Complete closed options/prompt validation, then workspace and skill resolution, fixed provider prefix admission, Req-defaults guard, keylog guard, Tidewave guard, bounded composition bootstrap, shared ReqLLM-start reconciliation, exact built-in provider-module verification, normalized explicit/default base URL, bounded session-owner activation and private root/subtree startup. The first failure wins; no later phase runs after refusal. The M6 Concept public table owns the complete code vocabulary and remaining startup detail. |
| Provider/address/ambient guards | Fixed composition reasons: `unknown_provider`, `provider_module_replaced`, `req_default_options_unsupported`, `ssl_key_log_enabled`, `req_llm_tidewave_enabled`, `provider_base_url_unsupported`. Ambient provider keys and active hosted/local tools are not refusal reasons. |
| Shared-start refusals | `req_llm_host_declaration_invalid`, `req_llm_dotenv_enabled`, `req_llm_already_started`, `req_llm_start_failed`; no global poisoned/admission-closed/credential-active code. An unavailable waiter returns fixed start failure; a later waiter may reconcile. |
| Model failure | Proved pre-call refusal is fixed `model_call_failed` with `not_dispatched`; started or unproved lifecycle paths use `dispatched_or_unknown`. Registered cleanup uncertainty withholds success/stop acknowledgement and closes only the affected handle. |
| Host release | A release embedding this in-VM adapter lists `req_llm`, `req` and `finch` as `:load`, not automatically started. The composition service starts them after hygiene guards; their code remains present in escripts/companion builds. |
| Skill-directory helper | `LoopexComposition.ResourcePacks.read_directories/2` is public in both profiles; M6 Concept states its complete options/return/error grammar. Admitted project/user identities, shadowing, digest retention and ADR 0025 activation are unchanged from the decision below. |

**Skills named by path.** Both profiles can admit exactly the skill directories
their host names. The ephemeral profile uses only those directories. For a
durable session, the public directory helper produces the existing resource
manifest and decision inputs; an embedding host passes that manifest through
the released `resource_manifest` option and drives ADR 0025's per-session
commands, while `ask --state-root` performs the same workflow. Named directories
are not a raw durable-composition option because those entrypoints create no
session and return no bootstrap decision. The rules:
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
  project skill is admitted and the user skill is reported by its exact
  `user:<name>` source id as shadowed.
- **Naming a directory is the host's admission decision.** It is recorded as
  ADR 0025's admission decision with `decision_source` `host_supplied`,
  `trust_scope` `project_skills` (the scope of skills admitted for this
  workspace's session), and the workspace binding. The host path is never
  recorded.
- **Admitted, then each activated,** so ADR 0025's separation between admission
  and activation holds, and its limit of four selected skills applies. In the
  durable profile the admitted snapshot is retained under the state root and
  the admission journaled, like any admitted pack's. The ephemeral API returns
  no handle until admission and every ordered activation succeeds; a failure at
  either boundary runs the same bounded startup rollback and no prompt,
  provider call or tool effect can precede it.
- **Where the durable profile takes them.** Named skill directories enter a
  durable session through the helper, released resource-manifest path and ADR
  0025 commands, or through `ask --state-root`, and the offline `loopex resume`
  reloads them by digest. The daemon is
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
   model boundary for each call. ADR 0019's 1-to-65,536-byte bound remains
   unchanged. The durable profile keeps the single source.

What the ephemeral profile gives up is process isolation for the credential and
the request during a call. Loopex bounds its owned call processes and result
route by locally tearing down the caller and tagged pool before a provider
result or successful cleanup acknowledgement. A checked-out socket and its OTP
TLS controller can drain afterward under the separately tested threshold; the
host environment and any host-made diagnostic copy retain the host's lifetime.
That trade is the point of the profile, and it is stated wherever the profile
is offered.

**The `ask` command's machine contract.** Other agents and scripts parse it, so
it belongs to this decision as an experimental surface:
- **JSON:** `--output json` writes the compact encoding of exactly one JSON
  object followed by exactly one LF, and no other standard-output byte. Its
  members are exactly:
  - `schema`, always `loopex.ask/1`;
  - `session_id`, `run_id`, `profile` and `outcome`;
  - `text` and `text_truncated`;
  - `tools`, each with its tool id and outcome, and `tools_truncated`;
  - `shadowed_skills`;
  - `cleanup`: for the ephemeral profile, whether stopping proved the run
    ending, effect cleanup, executor process groups, and every child of the
    per-session store, lease, executor, trace-capability and runtime subtree ended and then
    removed the temporary root, and if not, the named path, whether its exclusive
    root claim proved ownership, and the cleanup or removal obligation that
    remained. Unknown ownership occurs only when the exclusive mkdir return is
    lost; that path is diagnostic and never deletion authority. Cleanup is
    `null` for the
    durable profile, whose state remains resumable after the offline command's
    BEAM exits but for which `ask` performs no ephemeral cleanup proof;
  - `details`, whose members are fixed per outcome.

  The embedded API's cleanup error additionally carries a fixed failing-step
  cause when startup rollback cannot be proved; ordinary stop cleanup carries
  no cause. The command's closed JSON deliberately does not add that API-only
  member: a pre-run startup cleanup failure has status 1 and no result object.

  A `run.finished` field outside that set is not emitted. Every string and
  list has a stated bound, and a longer answer or tool list is cut and flagged.
  For `no_ending`, `details.reason` is exactly `timeout` when the follow wait
  expires or `session_unavailable` when the command or attachment path fails
  after a prompt may have been admitted while the command is still waiting;
  `details.waited_ms` is the elapsed wait. Every member also has one fixed type: when a run has no assistant text,
  `text` is `""` and `text_truncated` is false; absent tool and shadowed-skill
  values are empty lists with false truncation flags; `run_id` is null only for
  `no_ending` when no run id was learned; and `cleanup` is an ephemeral proof
  object or null for the durable profile. A refusal before the run, a
  cleanup-only failure before prompt admission, or an unmarked
  session-owner failure for which no public cleanup proof can be constructed,
  writes nothing to standard output even when the last case raced after a run
  observation; standard error names the command failure and any root available
  from a cleanup map. The one exception is the named ordinary worker-reap hard
  halt, which terminates before rendering and promises no output. JSON mode
  emits no text-mode tool or ending summaries: its
  standard error is empty for a proved run or no-ending observation, contains
  only the retained-root line for unproved cleanup, or contains only the fixed
  diagnostic for a status-1 command failure.
- **Exit status:** `0` completed; `1` refused before the run, failed cleanup
  before any run observation, or failed outside a run outcome without a public
  cleanup proof, including the named no-output ordinary worker-reap hard halt;
  `2` failed; `3` bound reached;
  `4` outcome unknown; `5` cancelled; `6` no ending after a prompt may have
  been admitted because the follow wait expired or the session path became
  unavailable; `130` the existing interrupt. The values avoid the daemon's 65–111 and
  the launcher's 127. An unproved cleanup does not change the status; it is
  reported in `cleanup` and on standard error.
  Ephemeral `ask` starts its worker only after the correlated ask-mode signal
  handler is installed. Installation or later handler loss performs bounded
  stop, writes no result and exits 1 rather than claiming interrupt handling.
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

This decision clarifies the vision's durable-session scope and amends its
credential rule. The paired vision files change with its acceptance:

- **Durability clarified.** Concept vision §12's survival guarantee applies to
  profiles Loopex represents as durable. A profile may be explicitly
  non-durable only through an accepted decision that names its lifetime,
  absence of recovery and migration path and uses the in-memory posture
  technical §12.2 already admits. ADR 0039 is that decision for the ephemeral
  profile; the profile never appears in a durable listing or root and reports
  no recovery capability.

- **Principle changed.** The vision's technical §12.7 excludes known
  credentials from crash reports, its §6.2 counts crash detail and traces as
  the diagnostics plane, its §16 says observability never captures secrets,
  its §23 verification rule says known credential material never appears in a
  prohibited plane, and AGENTS.md repeats the exclusion as a non-negotiable.
  In ADR 0039's ephemeral profile, which runs the provider library in the host
  VM, a credential may be present during a call in the sensitive caller,
  its provider-library HTTP and TLS state, their crash reports, a crash dump
  and provider-library telemetry arguments. Before a provider result or a
  successful cleanup acknowledgement, Loopex proves the caller and tagged Finch
  pool gone, with TLS resumption, tickets and secret retention disabled. A
  checked-out socket and its OTP TLS controller may then drain asynchronously;
  under isolated release conditions the witness requires both gone within
  5,000 ms of caller `DOWN`, but runtime cleanup does not wait for or prove that
  threshold. A host telemetry handler may keep a copy for any lifetime. A
  credential-bearing endpoint is
  HTTPS-only, so this exception admits no plaintext network exposure. §12.7's
  "narrowest possible lifetime and audience" also yields for the host
  environment: any code in that VM may read the value while the host keeps it
  there. Every Loopex-owned provider-handling exclusion stands, including reference-only runtime
  state, just-in-time resolution and host custody.
  Hosted and local tools are permitted even with ambient credential variables.
  A policy-authorized tool or trusted host-VM code may read or disclose those
  values, including through their ordinary tool output/effect planes; the
  profile provides no isolation from that audience. The selected
  model key is still excluded from the mapped provider reply and Loopex-owned
  diagnostics. Cleanup uncertainty closes only the affected session's
  admission; no shared gate, lease, quarantine or VM-restart lockout exists.
  Shared dependency outages remain possible and are not disguised as an
  independent-session availability guarantee.
- **Host resolution.** Vision §6.1 gives the host credential resolution. Here
  the host resolves by placing the value in a variable it names in its own
  environment; the adapter reads that host-supplied value at the model
  boundary, as the vision's "resolution occurs just in time at the approved
  model boundary" allows, and Loopex stores only the variable's name.
- **Where it lands.** Seven places gain the same scoped decision, in the
  exact text ADR 0039's technical companion gives, in the change that accepts
  this decision: `docs/vision.md` §12 and §16; `docs/vision-technical.md`
  §6.1, §6.2, §12.7 and §23; and AGENTS.md's "Credentials and context"
  non-negotiable, which needs the maintainer's explicit approval.
- **Evidence.** Successive external reviews of this decision tried to keep a
  credential structurally out of an in-VM ReqLLM call: a custodian with a
  value-redacting logger filter (the filter's readable value set, its
  contiguous-match limit and its release before ReqLLM's processes ended), then
  a credential-free in-VM path beside the companion (ReqLLM's Task and
  metadata processes, Req defaults, redirects and pool changes that carry a
  request out of the caller). Each exposed a path through the host's global
  configuration or ReqLLM's process structure that Loopex does not own. Later
  reviews rejected a shared HTTP/2 pool because it could resend below Req's
  retry control, and a shared HTTP/1 pool because `Connection: close` does not
  require the peer to close and OTP may retain TLS resumption state. The
  call-owned tagged HTTP/1 pool, one-shot adapter fence, hosted-provider HTTPS
  requirement and disabled TLS retention close those paths. The next
  adversarial pass extended teardown to pre-adapter failures and narrowed the
  key-log-file claim to distinguish Loopex's pool from host-started Req state.
  The maintainer approved one in-VM ReqLLM path for every provider in the
  ephemeral profile over carrying the companion into it.
- **Compatibility impact.** The durable provider path and daemon keep their
  accepted separate-process credential handling. The provider-call exception
  concerns hosted ephemeral calls; the ambient-tool audience exception covers
  both hosted and local ephemeral sessions.
- **Migration path.** A host that needs provider-process isolation composes the
  durable profile. A local ephemeral model alone does not isolate ambient keys
  from tools. A credential-free local alternative needs a host and tool audience
  that have no access to those values. A later decision may add a companion path
  to the ephemeral profile.

<a id="concept-adr-0039-consequences"></a>
### Observable Consequences

Technical depth: [Adapters and proofs](0039-ephemeral-embedded-profile-technical.md#technical-adr-0039-proofs).

- **Embedding.** An Elixir host that depends on `loopex_composition` calls:
  - `LoopexComposition.Ephemeral.run/2` for one answer;
  - `start_session/1`, `ask/3`, `answer/3`, `last_result/1`, bounded
    `history/1` and `stop_session/1` for a conversation. The session value is an opaque in-VM
    handle the host passes back and never inspects, like a runtime reference;
    the process that calls `start_session/1` owns its lifetime. Other processes
    may use the handle, but passing it does not transfer ownership: creator
    exit starts bounded cleanup and makes borrowed handles unavailable. What
    the host may read comes back in a terminal observation or no-ending
    snapshot, which carries the session id and the profile. Acceptance of a new
    prompt clears `last_result/1` to `:none`, and acceptance of an answer clears
    the answered question. The public wait deadline does not kill a granted
    facade call. Before the owner grants it, timeout cancels with no possible
    admission and preserves `last_result`; afterward the one command resolves
    under its independent bound. Late refusal preserves the prior observation;
    late acceptance stores the timeout snapshot and the sole owner drains until
    the next question or ending replaces it. Another ask reports `run_open`
    while the granted command is unresolved or its run remains open. A caught command or attachment
    failure after possible prompt admission but before a terminal event leaves
    the run-ending obligation unproved. A waiting `ask/3` or `answer/3` receives
    `cleanup_unproved`, which names the retained root and keeps the same partial
    projection under its `session_unavailable` ending; that no-ending value is
    not returned directly as proved cleanup. Before admission, proved cleanup returns the
    bare lifecycle error; unproved cleanup names the root. After the owner itself crashes, or
    when the background drain fails after the waiting call already timed out,
    the handle can report only the bare lifecycle error; the earlier timeout is
    then the only public observation. An unproved cleanup in that no-waiter
    branch can expose its retained root only through the host logger;
    standalone `ask` suppresses that logger and can leave the root unnamed.
    The boundary validates the complete pending-interaction shape and every
    public terminal numeric member before exposure. A malformed replayed value
    or out-of-domain wall-clock sample is never projected: it selects bare
    `session_unavailable`, performs bounded cleanup and exits unmarked. Unproved
    cleanup overrides the bare value with `cleanup_unproved` and no ending; an
    invalid terminal leaves run ending permanently unproved and does not claim
    the later, unevaluated effect-cleanup obligation.
    A cleanup error from failed startup carries the fixed failing-step cause;
    ordinary stop cleanup carries no cause.
    If the session owner dies after activation but before
    returning a handle, the entrypoint returns bare `session_unavailable`; it
    never becomes a replacement owner or invents a cleanup map. Before the
    root-start grant no root exists; afterward a root may remain unnamed.
    A non-creator process that dies while waiting in `ask/3` or `answer/3`
    does not end the creator's session. Before the request can have reached core
    it has no effect; after the conservative possible-admission boundary the sole owner lets the command resolve.
    Refusal preserves the prior observation; acceptance clears it to `:none`
    and drains to the next question or ending. One validated ask or answer owns
    a single public-mutation slot before its actor grant: a concurrent ask
    reports `run_open`, a concurrent answer reports
    `invalid_interaction_answer`, and neither waits in a queue. If the creator exits
    while a borrowed request remains registered, that borrower receives the
    serialized, admission-state-specific result before the owner exits: a
    pre-admission request gets no invented ending, while a possibly admitted
    request receives a cleanup error containing the bounded no-ending projection
    unless a terminal event wins; creator exit still
    creates no retry state.

  It needs no caller-supplied or durable state root, companion build or store
  setup. Hosted models need only the selected provider variable. A failed
  effect/process-group/runtime/subtree proof or root removal keeps the owned
  temporary root and names only obligations the owner reached and could not
  prove. Root removal is reached only after all owned resources are proved
  ended. A surviving handle may retry stop for a retryable subtree/removal
  obligation; irreversible run-ending, effect or group uncertainty remains
  explicitly unproved. One-shot/no-waiter paths retain their named logger-only
  root limitation. The affected session alone remains sealed; no cleanup
  result requires a VM restart or denies another session.
  A successful stop atomically marks the opaque handle closed and ends its owner:
  another stop is `:ok`, other calls report `session_closed`, and an owner that
  died without that mark reports `session_unavailable` rather than implying
  cleanup succeeded.
  The first accepted stop atomically enters a stopping state. Concurrent stops
  share its one bounded result; every later non-stop request returns
  `session_unavailable` immediately and cannot start work or wait behind cleanup.
- **Shells and agents.** They run `loopex ask "…"`, or `loopex -p "…"`, with
  `--model`, `--output json|text`, `--skill-dir DIR` (at most four, project or
  user skill directories) and a named policy. The exit status reports the run's
  outcome, not only whether the command started. The named unmarked-owner or
  owner-loss limitation is outside a run outcome: without a public cleanup
  proof, the command emits no JSON object and exits with the command-error
  status even if it had already observed the run. For an ephemeral command, a
  run observation stays provisional until its worker is proved ended through a
  private 1,000 ms reap, the command performs the mandatory bounded session stop
  and one serialized signal-handler decision chooses ordinary completion or
  interrupt. A still-unproved worker makes the command hard-halt status 1 with
  no output or cleanup claim. Only the proved path can render; a normal result
  leaves no live ephemeral handle. Before a handle exists, the launcher
  latches and forwards the signal and reaps the child, but ADR 0039 promises no
  Loopex cleanup or portable exit status for that interval.
- **Operators.** `--state-root` on `ask` selects today's durable behaviour plus
  named skill directories; the durable composition API gains the optional
  model, bound, sampling and active-tool options, while embedders use the helper
  plus its released resource-manifest path for named directories.
- **Profile visibility.** The embedded API's session value and result, and
  `ask`'s JSON, carry the profile, and an ephemeral session appears in no
  durable listing.

<a id="concept-adr-0039-compatibility"></a>
### Compatibility and Rollback

Technical depth: [Compatibility mechanics](0039-ephemeral-embedded-profile-technical.md#technical-adr-0039-compatibility).

This adds the profile and narrowly reworks two private companion mechanics:
- **Unchanged:** the public session protocol, the store format, the executor
  protocol, the daemon, the companion's valid request and reply behavior and
  core's runtime library.
- **Corrected companion edge behavior:** a malformed binary tool-argument
  payload that reaches the dependency-visible mapping seam fails the whole
  started call instead of being replaced by an executable empty object. A
  visible provider-executed or provider-native call likewise fails instead of
  being flattened into a replayable local tool request. The
  dependency-normalized erased cases named above remain unchanged.
- **Corrected companion deadline mechanics:** ReqLLM's relative total,
  stream-idle and receive waits become infinite so the unchanged coordinator's
  sliced committed deadline remains the one authority, including at the new
  unsigned-64-bit durable bound.
- **Amended:** Concept §12 and §16, Technical §6.1, §6.2, §12.7 and §23,
  and AGENTS.md, for the ephemeral profile only.
- **Experimental** under the 0.x policy:
  - the embedded API;
  - the `ask` command;
  - `LoopexComposition.ResourcePacks.read_directories/2`;
  - the durable composition's optional model, bounds, sampling and active-tool
    options, whose defaults reproduce M5.
- **New edge modules behind unchanged ports:** the memory store and the
  in-process adapter. Core's dependency budget is unchanged.
- **Durable policy revision:** the durable composition's default policy
  identity keeps the revision it had in `0.2`, fixed rather than derived from
  the release version, so a pending interaction recorded under either release
  recovers under the other.
- **Rollback** to `0.2`: remove the profile. No durable byte depends on it, and
  a `0.2` binary opens and resumes every root `0.3` writes, with the stated
  rollback limitations and a truthful record:
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
    Its released CLI/daemon cannot discover a new external user skill. This
    does not constrain arbitrary embedding-host manifests.

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |
