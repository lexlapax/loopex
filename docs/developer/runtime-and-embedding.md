# Runtime and Embedding

<a id="concept"></a>
## Concept

M1 turns the minimum single-machine coding-agent trace into product code: an
embedded host starts an explicit OTP runtime, creates or resumes a durable
session, attaches at a public-event cursor, submits a prompt, and lets the
runtime coordinate model and controlled-tool turns. The host supplies authority
and concrete edges; the runtime owns loop ordering and durable session truth.

The embedded API is a direct facade, not a transport or fourth boundary
behaviour. `Loopex.ReferenceClient` demonstrates that a thin caller needs no
coordinator access, Store access, alternate reducer, policy engine, or event
truth of its own. The M1 surface is unreleased and carries no compatibility or
packaging promise.

M2 keeps that shape and changes what an embedder has to assemble. The umbrella
is now eight applications: `loopex_composition` carries the reference stack an
embedder depends on instead of copying, and `loopex_cli` is a peer surface over
the same facade. Core gains two ports — the host policy and the artifact store —
and the runtime gains a tool set, declared run bounds, and transient progress
sinks as explicit start options. The turn machine itself is documented in
[Agent loop and tools](agent-loop-and-tools.md#concept).

`LoopexComposition` is one module of shipped code, not a wiring framework. It
names four concrete implementations, resolves its state root explicitly, and
refuses to start unless the host supplies the policy that governs the run. An
embedder who wants a different Store, Model, Executor, or ArtifactStore composes
the ports and the facade directly; a layer general enough to serve both waits
until a second real composition exists to give evidence for one.

Nothing in this milestone is frozen or labelled:
[Compatibility surfaces](compatibility-surfaces.md#concept).

M3 adds project skills through the same runtime. A host supplies one immutable
resource snapshot, explicitly admits its exact identity, and selects instructions
and supporting files before a run. The snapshot belongs to one workspace and one
runtime; sessions retain decisions and selections rather than copying the whole
pack set. A skill changes model input and never grants a tool permission.

Technical depth: [Resource snapshot and commands](#technical-embedding-resources).

M4 adds two embedding contracts to the same facade and one more surface beside
it. A host policy may now answer a tool decision with a question instead of a
verdict: the runtime commits that question as durable session state, suspends
the tool call, and asks the same policy again once an answer commits. An
embedder that wants this supplies a policy identity at launch and handles one
more command and one more family of events; an embedder that does not defer sees
nothing change. Separately, a host holding an artifact reference can read the
object back in bounded verified chunks instead of fetching all of it, where the
composed artifact store offers that capability.

The surface beside the facade is `loopex_app_server`, a foreground process that
speaks the experimental session protocol over standard input and output. It is a
peer client of the runtime, not a second runtime, and an embedder chooses
between calling the facade in process and driving that server from another
language. Its wire contract is documented in
[the app server protocol pair](app-server-protocol.md#concept).

Technical depth: [Durable interactions](#technical-embedding-interactions) and
[bounded artifact transfers](#technical-embedding-transfers).

The runtime also became observable from outside without editing it: a host
starts a runtime-scoped trace session over named Loopex modules and consumes
`:telemetry` spans at every port callback and coordinator transaction cut. Both
are bounded, both redact content, and neither is authority or durable truth. The
contract is the [observability pair](observability.md#concept), and the levels
and events an operator turns on are in the
[operator runbook](../operator/observability.md#concept).

Operator workflow and failure handling: [Runtime operations](../operator/runtime.md#concept).
Running a coding session: [Coding sessions](../operator/coding-sessions.md#concept).

<a id="technical-depth"></a>
## Technical depth

### Application and Dependency Shape

M1 had six applications; M2 has eight, adding one `:composition` and one
`:client`; M4 has ten, adding one `:edge` and one more `:client`:

| Application | Role | Production dependency direction |
| --- | --- | --- |
| `loopex_protocol` | contract | none |
| `loopex` | core | protocol, plus the one admitted external package `:telemetry` |
| `loopex_store_local` | Store edge | inward to core |
| `loopex_llm_reqllm` | model edge | inward to core; the one locked ReqLLM dependency |
| `loopex_executor_local` | executor edge | inward to core |
| `loopex_telemetry` | telemetry edge | inward to core; `:telemetry` only |
| `loopex_composition` | composition | core, protocol, and the three edges it composes; no external dependency |
| `loopex_reference_client` | client | inward to core; concrete edges only in tests |
| `loopex_cli` | client | core plus exactly one composition |
| `loopex_app_server` | client | core, one composition, and the contract application whose schema it speaks |

`:composition` exists because a wiring application needs exactly the direction
an `:edge` may not have and a `:client` may not be depended on for. It is the
one production role permitted to declare a dependency on the concrete edges it
composes, it declares no external dependency in any environment, and it depends
on no client and on no other composition. A `:client` may depend on at most one
composition, at most one contract application, and never on another client; the
contract edge exists so that the app server can name the schema it speaks in its
own project file rather than reaching it through core. Core declares exactly one
external package, `:telemetry`, pinned to `~> 1.3` and admitted by
[ADR 0030](../adr/0030-observability-tracing-and-telemetry.md#concept); it
attaches no handler of its own, and the only Loopex-attached handler lives in
`loopex_telemetry`. `mix loopex.deps_budget` enforces the inventory, the pinned
requirement, and every direction above.

Core defines five boundary behaviours. M1's three — `Loopex.Store`,
`Loopex.Model`, and `Loopex.Executor` — are joined by `Loopex.Policy`, the host
authority port, and `Loopex.ArtifactStore`, the spill port. `Loopex.Executor`
also gains one required `cancel/2` callback, recorded in
[ADR 0012](../adr/0012-executor-cancellation-capability.md#concept). Its exact
answers are `{:ok, :cleaned}`, `{:ok, :unconfirmed}`, and `{:error, term()}`;
the runtime treats every answer except confirmed cleanup as unconfirmed.
Runtime, composition, and client code introduce no sixth behaviour, broker,
generic operation layer, global registry, or alternate loop.

### Runtime Composition

`Loopex.start_link/1` requires `runtime_id` and a `Loopex.Store` handle. A working
loop additionally supplies all four loop inputs together:

- `model`: `%{module: module, model: model_spec, options: keyword}`;
- `executor`: the module/reference plus identity, executor epoch, fencing token,
  workspace reference, and workspace lease;
- `tool`: the provider-facing name, description, JSON input schema, governed
  tool ID/version, and effect class; and
- `grant_decision`: the explicit host result `{:host_policy, :allow}`.

Omitting the complete loop configuration retains the lower-level runtime and
embedded session API used by the Outcome 1–4 tests. Supplying only part of it is
invalid configuration; the runtime never infers a model, executor, tool, Store,
runtime reference, or policy decision.

M2 replaces the single `tool` declaration with a tool set and adds the options
the loop needs. `:tools` is the reference distribution's own declaration and the
only path by which a reserved `loopex.` identifier reaches the registry;
`:active_tools` selects which of them a session offers, defaulting to all of
them; `:policy` names the host authority module and is required whenever any
tool is active; `:bounds` and `:sampling` carry the declared run bounds and the
output allowance; and `:progress_to` and `:diagnostics_to` are optional
unsupervised sinks for transient items. The inherited `:tool` and
`grant_decision` options remain valid and are folded into the same tool set, so
there is exactly one way a tool reaches a model. Configured defaults exist for
the bounds — 16 turns, a 1_000_000-token budget, and a 600_000 ms deadline
duration — and for `max_tokens`; they serve a host that said nothing, and a host
that explicitly supplies a malformed value is refused at start.

Prompt admission records the deadline duration, and a queued follow-up
deterministically inherits it at promotion. The first staged model request turns
that duration into the absolute instant committed in its canonical bytes; later
turns, executor jobs, timers, and recovery reuse that exact instant. A run lost
before first staging therefore retains its full duration, while every outage
after staging consumes the already-committed deadline.

The root supervisor is unnamed and uses `:rest_for_one`. The tool registry now
comes first, because runtime control and every session coordinator resolve tools
through it; runtime control follows and precedes the task supervisor, dynamic
session supervisor, and event dispatcher, so loss of configuration or authority
removes later transient work. A caller retains the opaque runtime reference; no
application environment or registered process identifies an instance, and two
runtimes in one VM hold independent tool sets.

### Loop and Commit Ordering

One session coordinator is the serial writer for a session. M1's working loop
was one fixed trace of exactly two model turns and one forced tool call:

1. commit prompt admission;
2. build and commit the exact canonical model-request bytes and SHA-256 digest;
3. dispatch only that committed request through `Loopex.Model`;
4. commit the normalized model result and verify it echoes the exact bytes and
   digest;
5. for one forced tool call, build the canonical JobRequest and explicit grant,
   then commit effect intent before dispatch;
6. let `Loopex.Executor.Local` revalidate the job, grant, live lease, audience,
   expiry, epoch, identity, and fence at its final serialized pre-start boundary;
7. retain the executor receipt before returning it;
8. commit the validated receipt fact and corresponding public event before the
   second model call; and
9. commit the terminal model result and `run.finished` event.

M2 generalizes that trace without changing its commit discipline: intent still
commits before dispatch and facts before publication, and the coordinator is
still the sole serial writer. What changes is that the number of turns is
decided by the model and the declared bounds rather than fixed, that each
request is projected from committed elements rather than built from one message,
that a turn may carry several tool calls, and that a call is dispatched only
after the host policy allows it. The stage-by-stage ordering is in
[Agent loop and tools](agent-loop-and-tools.md#technical-depth).

Provider dispatch has two deadline fences around its one-use permit. Control
allocates the permit only after rebuilding the committed attempt binding and
takes its final clock sample immediately before sending it. The receiving
worker compares the committed deadline again immediately after receiving that
exact permit and before entering the adapter. Equality means the deadline has
been reached. A permit delivered late is retained conservatively as possibly
dispatched, never retried, and never turned into a provider call outside the
committed authority. The Store read that rebuilds the binding runs in a reader
owned by a separate guardian that monitors Control. Timeout cancellation or
Control death kills and awaits that exact reader, and a successful result is
forwarded only after the reader has exited. The adapter's result remains inside
its worker-provenance wrapper until admission, so its data cannot impersonate
the receiver's private deadline observation.

Before Control is asked to authorize that permit, the coordinator creates and
retains a dormant provider lifetime guard under the owner generation's private
supervisor, bound to the exact permit worker. The guard starts no adapter work
until that worker receives its permit and asks it to create a linked callback.
Catchable failures normalize inside the callback;
the trapping guard reduces asynchronous linked exits to the same fixed private
failure, waits for a successful callback to exit before forwarding its result,
and cannot finish while the callback lives. An adapter may synchronously register
one private resource guardian before releasing transport work. The reference
adapter uses that handle for an independent OS guardian retaining one companion
BEAM and its process group. ReqLLM and its transport processes run only in the
companion; protected entry suppresses child diagnostics without changing the
parent's Logger, application group leaders, or ReqLLM supervisor. Core's retaining
guard, rather than the short-lived adapter callback, owns resource lifetime.
Cleanup uses the already declared period and committed deadline; Core waits for
the registered resource process to exit, not merely for an acknowledgement.
Terminal data is not proof of process-group cessation. Every terminal path stops
and awaits both lifetime layers, and the generation barrier cannot fall during
abrupt owner loss until that supervisor has proved them down. Explicit host launch
settings are required; no ambient worker discovery or shared-VM fallback exists.

The adapter's complete raw reply, including every raw usage key and value, must
pass the Store's bounded plain-data admission and full canonical validation
before accounting. Store or canonical refusal yields an unreadable result and
charges the run's remaining allowance as estimated, even if one raw usage member
looks valid. Missing or invalid usage in an otherwise canonical reply has the
same accounting result. Only after full canonical success, when the complete
durable settlement itself fails the Store-size preflight, may the compact
unreadable settlement retain already validated reported usage.

The local executor separates queue ownership from effect authority. Its first
serialized decision reserves or joins a job but grants no permission to run.
The same server answers a second permit request only after checking the exact
live reservation holder, repeating complete root reconciliation after bounded
pre-start validation, and validating the job, grant, lease, and deadline. For
new work it publishes the durable open entry and marker and installs the exact
operation-owner token under the same root claim before returning a successful
permit; a joiner never owns or erases that token. If publication stops between
the open entry and marker, no owner token is installed and the unresolved entry
quarantines the root. A close that only partly changes the
ledger restores the open authority before releasing the claim or retains the
claim and quarantines the root when restoration cannot be proved, so unrelated
work cannot turn an ambiguous prior effect into permission. A missing or
oversized job identity is refused before ledger or reservation work. Filesystem
effects run under an owner-aware worker bound to the Local instance that
admitted them. Command launch also monitors the execute caller before the child
announces readiness, and a command's potentially proved result is checked
against the Local owner again after cleanup, so neither start nor final proof can
outlive its exact authority.

All durable and public boundary data is bounded plain data. Provider structs,
PIDs, functions, arbitrary terms, credentials, and implementation types remain
inside their owning edge or transient runtime process.

<a id="technical-embedding-resources"></a>
### Resource Snapshot and Commands

Concept: [Runtime and embedding](#concept).

The reference host's `LoopexComposition.ResourcePacks` owns discovery, pinned Git
acquisition, containment and retained provenance. `discover/2` walks only
`.agents/skills/<name>/SKILL.md` and bounded files inside each pack. `add/3`
requires an exact commit, selected directory and explicit acquisition authority;
installation does not admit content to a session. `retain/2` and `load/2` keep
the exact snapshot under its manifest digest in the state root.

Pass the verified manifest as `resource_manifest:` to the composition or core
runtime. Core validates it once and stores one copy in a protected unnamed ETS
table owned by the runtime supervisor. Child options keep the table reference,
not the manifest contents. The host may still retain its input copy; it owns that
additional residency. One snapshot binds one workspace for that runtime's
lifetime. A session for another workspace withholds this resource class instead
of borrowing another session's admission.

The host uses `Loopex.command/2` with `:admit_resources` and then
`:activate_skill` while the session is settled. Admission binds the manifest
digest and full decision; selection binds that digest, `source_id`, `name`,
`pack_digest` and ordered `supporting_labels`. A run freezes the resulting
selection. Repeated command IDs replay the retained outcome; stateful refusals
are retained too. A fresh admission clears earlier selections. There is no
model-callable selection or arbitrary-path resource query.

`Loopex.resource_catalog/2` returns catalog entries only for matching active
admission. `Loopex.read_resource/3` takes the exact manifest digest, source, name
and manifested label. Both are facade queries and grant no effect authority.
The complete manifest has at most 64 packs, 64 files per pack and 1 MiB content per pack,
64 MiB content overall and 8 MiB metadata. Selection is bounded to four skills
and eight supporting files each. These ceilings do not raise the existing
context or Store budgets.

Resource commands use `resource_command_v1`; admitted sessions stage through
`model_request_committed_resources_v1`. The durable reducer reconstructs exact
staged request bytes without any resource snapshot. For fresh-process CLI
recovery, a temporary composition prepares the session without activating work,
reads its admitted manifest digest and abandons the preparation. After confirmed
cleanup, the CLI loads that exact retained snapshot and starts the final
composition with the same trusted provider and executor configuration.
A future unstaged request
needs the matching retained snapshot or withholds resource content. It never
refetches or uses an edited workspace as the prior admission. See
[ADR 0025](../adr/0025-resource-packs-and-skill-admission.md#concept) for the
accepted format and [compatibility](compatibility-surfaces.md#concept) for the
old-reader refusal and rollback boundary.

<a id="technical-embedding-interactions"></a>
### Durable Interactions

Concept: [Runtime and embedding](#concept).

A host that wants to be asked supplies two launch options together: `:policy`,
the authority module it always supplied, and `:policy_identity`, a bounded
`%{"id" => binary, "revision" => binary}` pair. The identity is required
whenever a policy is named, because a retained question must be resumed by the
policy that asked it; a launch that omits it returns
`{:error, :policy_identity_required}` and a malformed one
`{:error, :invalid_policy_identity}`. `LoopexComposition` supplies a default of
the module's inspected name paired with `Loopex.version/0`, and defers to an
explicit value, so an embedder whose build can change what a policy module does
names its own revision.

The callback is unchanged. `Loopex.Policy` still declares one `decide/1`, and
ADR 0009 always declared `{:defer, request}` on it. What M4 adds is a second
caller: `Loopex.Policy.evaluate/2`, which the session coordinator uses, admits a
validated defer, while the inherited one-shot `Loopex.Policy.decide/2` still
resolves one to `{:deny, :interaction_unsupported}`. A host cannot tell which
caller it is answering, and a defer outside the admitted question family
resolves as `policy_unavailable` rather than creating a malformed question.

The admitted question family is exact, and `Loopex.Interaction.bounds/0` returns
it as data so a host can check a question before offering it: `kind: :choice`;
a non-empty UTF-8 `prompt` of at most 2,048 bytes; one to eight `choices`, each
with a unique identifier of 1 to 64 bytes and a non-empty label of at most 256
bytes; `expires_in_ms` between 1 and 600,000; and an optional bounded
`decision_ref` of at most 256 bytes which is retained privately and never
projected.

The lifecycle is four transitions, each one journaled before anything observable
follows from it:

1. **Request.** A defer commits `interaction_requested_v1` and publishes
   `interaction.requested` in the same transaction. The tool decision and the
   run suspend: no grant is minted, no effect intent is committed, and no
   executor process starts. The record binds the original bounded policy
   request and its digest, the validated question and its digest, the policy
   identity and revision, the creation instant, the effective expiry, and the
   round.
2. **Answer.** `Loopex.command/2` admits
   `%{type: :interaction_answer, command_id:, interaction_id:, choice_id:}`.
   It is an ordinary durable session command keyed by `(session_id,
   command_id)`, so an identical replay returns its historical admission and
   changed content under the same command ID conflicts. Admission means the
   answer committed, never that the effect is allowed. An answer naming a
   question that is not open, a different question than the open one, or a
   choice that was never offered is refused with a stable reason —
   `interaction_absent`, `interaction_resolved`, `invalid_interaction_answer` —
   and none of them reopens anything.
3. **Resolution.** The coordinator calls the same host policy again with the
   original request's exact fields plus one core-created `interaction_response`
   member carrying the interaction identity, the validated question, the
   admitted answer and its digest. Only a committed `allow` may supply the
   bounded grant reference, and grant binding and effect intent still commit
   before dispatch. The resolution commits `interaction_resolved_v1` and
   publishes `interaction.resolved` with `allowed` or `denied`. Denial,
   malformed policy output, timeout and failure each dispatch nothing.
4. **Expiry, abort and deadline.** The effective expiry is the earlier of the
   requested duration from the committed creation instant and the run's own
   absolute deadline, chosen once before the creating transaction so two owners
   recovering the same creation cannot give the question two lifetimes. Expiry
   publishes `interaction.expired` and resolves the tool decision as a denial;
   it adds no new run-terminal outcome. An abort publishes
   `interaction.cancelled`, and a later answer finds the question resolved.
   Expiry, answer, abort and deadline are ordinary competing transitions
   ordered at the journal, and the first committed one wins; a timer that fires
   for a question this owner no longer holds open changes nothing.

Another defer resolves the current question and creates a fresh interaction
identity with the next round number. At most one interaction is open per
session at a time, and a tool decision admits at most two successive
answer-then-defer rounds after the first question — three questions in total.
The next defer fails closed as a denial.

Restart is the point of all of this. A recovered coordinator re-arms the
expiry timer only for a question still `pending`; an `answered` question is
owed a resumed evaluation instead, and arming a timer against it would race the
host's own answer. A crash between answer admission and resolution leaves the
run suspended: no recovery branch speculates, acknowledges permission, or
dispatches first, and re-running the evaluation is safe precisely because it
authorizes nothing until its result commits. If the current `:policy_identity`
does not equal the one retained with the question, the session stays suspended
and dispatches nothing rather than letting a different implementation, or a
different revision of the same one, decide what a committed answer meant.

A caller reads the open question from two places, both bounded and both carrying
the public view only: `Loopex.attach/2` and `attach/3` return an
`open_interaction` beside the unchanged revision-2 snapshot, captured at that
same cursor, and `Loopex.session_status/2` reports it at the cursor it names.
The view carries the identity, prompt, offered choices, expiry and status; it
never carries the host's `decision_ref`, and it carries the selected choice only
after an answer was admitted. Transport loss by itself changes no interaction
state, which is what lets a new app-server process present the same question.
The accepted contract is
[ADR 0024](../adr/0024-durable-interaction-lifecycle-and-host-policy-authority.md#concept),
and the witnesses are in `apps/loopex/test/interaction_lifecycle_test.exs`.

<a id="technical-embedding-transfers"></a>
### Bounded Artifact Transfers

Concept: [Runtime and embedding](#concept).

A caller that holds an artifact reference can read the object back through an
attachment in three calls:

```elixir
request = %{object: object, use_locator: reference.use_locator, start: 0}
{:ok, transfer} = Loopex.open_artifact_transfer(attachment, request)
{:ok, chunk} = Loopex.read_artifact_chunk(attachment, transfer.transfer_ref, 8_192)
:ok = Loopex.close_artifact_transfer(attachment, transfer.transfer_ref)
```

The request names the artifact a caller already holds, a non-negative `start`
and an optional `length`. The store verifies the complete immutable object
exactly once at open, before any chunk exists, and the response carries
`total_size`, `window_start`, `window_length`, the `object_digest` and an opaque
`transfer_ref` — and no placement: a caller learns the window and the digests,
never where the bytes live. Each chunk then carries its own `offset`, `bytes`
and `chunk_digest` covering exactly those bytes, which is deliberately a
different digest from the one covering the object, so a reader can check what it
just received without being told a chunk hash proves the whole. Chunks are
contiguous from the window's start, never cross it, and are bounded by the chunk
ceiling however much a caller asks for. `{:ok, :complete}` means the window is
exhausted; the transfer stays open until it is closed or its lifetime ends.

Saving an N-byte object therefore reads at most 2N bytes: one verification and
one emit, not one verification per chunk. The ceilings are returned as data by
`Loopex.ArtifactStore.transfer_limits/0` and are safety ceilings rather than
measured throughput promises:

| Ceiling | Value |
| --- | --- |
| `object_bytes` | 67,108,864 |
| `open_deadline_ms` | 60,000 |
| `open_work_bytes` | 134,217,728 |
| `chunk_bytes` | 32,768 |
| `read_deadline_ms` | 5,000 |
| `lifetime_ms` | 600,000 |
| `per_attachment` | 2 |
| `per_runtime` | 4 |

Ownership is the other half of the contract. A transfer belongs to the
attachment that opened it: another attachment reading its reference gets
`unknown_transfer`, the superseded attachment gets `stale_attachment`, and
replacement, detach or caller loss releases every transfer that attachment held.
Refusals are distinct and stable — `invalid_window`, `artifact_use_mismatch`,
`unknown_artifact_use`, `artifact_digest_mismatch` for corruption anywhere in
the object, `open_deadline_exhausted` and `open_work_budget_exhausted` for an
open that exceeds its budget before retaining any bytes, `transfer_limit_reached`
for the per-attachment and per-runtime ceilings, and `unknown_transfer` for one
that expired or was closed.

The capability is optional on the port. `Loopex.ArtifactStore.transfer_capable?/1`
asks the composed module rather than assuming, and a runtime composed without an
artifact store, or with an adapter that predates the decision, answers
`artifact_transfer_unsupported` rather than falling back to an unbounded
`fetch/2`. The four inherited callbacks answer exactly as before, genuine old
artifacts stay readable, and removing the capability restores the prior API
without rewriting data. The accepted contract is
[ADR 0028](../adr/0028-bounded-artifact-retrieval.md#concept), and the witnesses
are in `apps/loopex_store_local/test/artifact_transfer_test.exs`.

### Embedded API

The host-facing sequence uses the public facade only:

```elixir
{:ok, runtime} = Loopex.start_link(runtime_options)
{:ok, session_id} =
  Loopex.create_session(runtime, %{"workspace" => "example"}, command_id: "create-1")
{:ok, attachment} = Loopex.attach(runtime, session_id, after_event_sequence: 0)
{:accepted, "prompt-1"} =
  Loopex.command(attachment, %{type: :prompt, command_id: "prompt-1", content: "Do it"})
{:ok, event} = Loopex.next_event(attachment)
:ok = Loopex.stop(runtime)
```

`runtime_options` must include a positive `:context_token_budget` chosen by the
direct host; Core Runtime supplies no default. It also carries the session's
`:cleanup_grace_ms`, whether chosen explicitly or resolved by that host before
start. Those are committed run/session policy, not adapter configuration, and a
restart or recovery never substitutes its current process defaults for the
retained values.

`Loopex.snapshot/1` returns the attachment's exact durable anchor, taken by a
scan that stops at the acknowledged position rather than at the durable tail, so
the anchor never derives run state from a row delivery is still withholding.
`Loopex.attachment_status/1` reports bounded transient queue information.
`Loopex.progress/2` and `Loopex.diagnostic/2` are transient. None of those
observations grants authority or substitutes for Store history.

`Loopex.next_event/1` delivers only rows the runtime has acknowledged as
resolved. A row that is durably linearized while its owner still holds an
unresolved transaction is withheld until re-presentation settles it, so a
caller never reads a fact the owner is not yet able to stand behind. Cursors and
gap semantics are unchanged; the fence delays a read rather than reordering or
dropping one, and it is released when this runtime stops owning the session. The
attach scan obeys the same bound, so an attachment installed under an unresolved
transaction never anchors past what its first read may deliver.

Recovery that may race an operator interrupt is deliberately two phase.
`prepare_resume_session/3` and `prepare_resume_known_session/4` return either a
replayed result or an opaque one-use activation capability while recovered work
remains paused. The coordinator monitors the initial preparer before returning
that capability; preparer loss permanently abandons unspent authority. Only the
current holder may activate, abandon, or transfer it.

`transfer_resume/2` preserves ordinary transfer and its PID domain. The
coordinator records the new holder before replying. It never selects another
protocol from ambient process state. Loss of the caller before its reply leaves
the result unknown to that caller.

`transfer_resume(activation, holder, {participant, correlation})` explicitly
adds a local lifetime participant under
[ADR 0020](../adr/0020-explicit-prepared-handoff.md#concept). The calling holder,
receiving holder, participant and coordinator must be distinct local processes;
correlation is a fresh local reference. Malformed or aliased roles and non-local
correlation references return `invalid_resume_handoff`; a non-local role returns
`non_local_resume_participant` before liveness checks or mutation. The full
independently implementable message protocol is documented on
`Loopex.ResumeActivation.transfer/3` and in
[the technical decision](../adr/0020-explicit-prepared-handoff-technical.md#technical-adr-0020-decision).
No CLI implementation or private capability inspection is needed to implement
that participant.

The participant establishes its preparer, holder and host dependencies before
the receiving holder becomes reachable. The coordinator prepares one exact
relationship asynchronously, then sends an authorization through the calling
holder. Acceptance of the forwarded authorization by the participant is the
lifetime linearization: it retires the preparer dependency and acknowledges to
the coordinator. Forwarded authorization and later preparer death are consumed
in sender order. The coordinator records the acknowledged holder before
returning `:ok`, preserving every intervening abort or owner fence. Initial
preparer death cannot revoke a handoff whose participant already accepted it,
even when the public reply is lost.

`LoopexCli.Interrupt.install_prepared(attachment, cleanup_ms, activation)`
supplies its guard as that participant. The guard monitors the installer before
creating its linked, monitored holder, and arms the exact signal manager before
installation exposes the holder. The link also ends a blocked holder if the
guard dies. Handler installation atomically claims one manager-local identity.
A duplicate returns `interrupt_already_installed`, disposes its own candidate
participants, and preserves the incumbent attachment, holder, abort identity
and backstop. Initial installation maintains signal coverage while removing
the default termination handler. There is no dynamic replacement or predecessor
drain.

Installation propagates `:ok`, definitive refusal, or `{:unresolved, reason}`.
An unresolved result keeps recovery fenced and lifetime cleanup active; the
command reports uncertainty and does not activate or retry speculatively.
Activation and abandonment presentations wait for exact owner results in the
holder, while their read-only holder lookup has an independent bounded wait and
reports unavailable on expiry. A suspended manager is not an absent manager.
Holder or coordinator loss during a presentation is unresolved, because stopping
a presenter cannot withdraw a request already received by the owner.

The signal manager remains responsive while the holder waits: signals submit
the ordinary abort asynchronously and arm the configured backstop. Orderly
handler removal releases its holder asynchronously; abrupt exact-manager or
coordinator loss independently ends even an idle holder. These losses abandon
only still-prepared authority. A session whose activation already succeeded
owns its admitted work and is not terminated by holder cleanup. No transient
capability, PID, reference, or participant value enters durable or printable
public data. Rollback terminates the transient command participants before
restarting a coherent prior composition; it never translates a live capability
or undoes an admitted activation or abort.

### Reference Composition

`LoopexComposition` wires the reference local stack in one module under a
hard ceiling of one hundred eighty effective lines, counting neither blank lines
nor comments. A private `RuntimeOwner` supplies the shared startup and cleanup
lifecycle. `start/1` starts the applications an `escript` does not start for it,
opens the durable store and the artifact store under the caller's resolved state
root, opens a workspace lease and the local executor, and returns a runtime
already composed with the four bootstrap coding tools:

```elixir
{:ok, runtime} =
  LoopexComposition.start(
    runtime_id: placement_id,
    state_root: state_root,
    workspace: workspace_path,
    policy: MyHost.Policy,
    context_token_budget: 8_192,
    cleanup_grace_ms: 5_000,
    progress_to: self()
  )
```

`:policy` has no default and its absence returns `{:error,
:host_policy_required}`. The composition owns wiring and never authority: a
permissive default shipped here would answer the host's question once for every
embedder that depends on it, which is why both permissive policies in this
repository live in clients an operator must name.

The composition's reference context policy defaults omission to 8,192 estimated
tokens and forwards an explicit valid `:context_token_budget` unchanged as
Runtime's required top-level option. The estimate is neither provider capacity
nor billing. Its cleanup default is likewise resolved before Runtime and Local
start so the session, executor, and command observe one committed value.

`:state_root` and `:workspace` are resolved by the caller, never discovered
here, and no value is read from application environment.

Use `with_runtime/2` when the reference stack is needed for one operation:

```elixir
LoopexComposition.with_runtime(runtime_options, fn runtime ->
  Loopex.create_session(runtime, %{"workspace" => "example"}, command_id: "create-1")
end)
```

It returns the callback result after `Loopex.stop/1` succeeds and the directly
owned executor, workspace lease and Store report orderly shutdown. A normally
returning callback receives `{:error, {:composition_cleanup_unconfirmed,
details}}` if cleanup required force or could not be confirmed. Unexpected
runtime death returns `composition_runtime_stopped`; owner failure returns
`composition_owner_failed`. Exceptions, throws and exits from the callback are
re-raised after cleanup. Caller loss also starts cleanup. `start/1` retains its
independent-owner lifecycle. If shutdown remains unconfirmed after the error is
returned, the private owner retains and monitors those process identities until
they stop.

`LoopexComposition.artifacts/1` returns the artifact-store handle on its own,
because an artifact outlives the run that produced it and an operator
retrieving one later needs no runtime.

It ships as an application rather than as a snippet in a guide because a snippet
is re-derived once per embedder and goes stale silently the first time the
kernel's start-up shape changes; a shipped application changes once and breaks
the build of every dependant that must change with it. It is deliberately not a
generic wiring toolkit: it names `Loopex.Store.Local`, `Loopex.LLM.ReqLLM`,
`Loopex.Executor.Local`, and `Loopex.Store.Local.Artifacts` in this one place,
which is what makes the dependency direction checkable and what makes it
unusable for an embedder who wants a different implementation of any of the
four. That embedder composes the ports and the facade directly. With exactly one
implementation of each port in the inventory, a general wiring layer would have
no second composition to give evidence for its abstraction.

### Recovery

The host reopens the local Store with `recover_stale_writer: true`, which the
store honours only after asking the operating system whether the marker's
recorded holder is still alive. The marker (`loopex_store_writer_v2`) carries
the holder's operating-system pid, its start identity as `/bin/ps` reports it,
its BEAM pid, and a nonce: a live holder is refused as `store_writer_active`
whoever asks; a holder that is gone or whose start identity no longer matches
its pid is recovered; and a marker the store cannot verify — unreadable bytes,
a record from an earlier version, or a probe that failed, printed a diagnostic,
or did not answer within five seconds — is refused as
`store_writer_unverifiable` naming the path and the reason, which is a human
decision rather than an automatic one. Only the exact "no such process" answer
counts as absence. A store that cannot record its own identity refuses to open
at all (`store_writer_identity_unavailable`), because a marker without one
could never be recovered afterwards. The host then starts a
replacement runtime with the same placement identity and calls
`Loopex.resume_session/3`. The new coordinator
discovers unresolved succession state, resolves the exact prior transaction,
reads the non-authorizing ownership head, and commits a fresh owner succession
before routing commands.

An effect whose committed intent lacks a committed fact remains
`effect_dispatched`; recovery never starts executor work from that state. The
caller requests `Loopex.reconciliation_query/1`, retrieves the retained receipt
from its executor authority, constructs either
`Loopex.ReferenceClient.Recovery.receipt/2` or `outcome_unknown/1`, and submits it
with `Loopex.reconcile/2`. The current coordinator validates every query and
origin binding before committing one receipt fact or terminal unknown outcome.

A prepared resume settles that effect itself where its executor can say what it
retained. Activating the prepared owner is the host's statement that the process
which dispatched the effect is gone, so no result is coming back through the
coordinator and the executor's retained receipt is the only truth left. The
coordinator therefore solicits its own query at activation, asks the executor
through the optional `Loopex.Executor.retained_receipt/2` callback, and validates the
answer exactly as it validates a host's: a retained receipt commits the receipt
fact and the run continues; `:absent`, `{:error, :effect_unresolved}` (an
admitted job this Local does not hold, with an open entry and no final receipt),
and `{:error, :effect_settling}` (a receipt whose open entry still stands) each
commit `outcome_unknown`, because none is a final fact from which this recovered
owner may resume or re-dispatch, and the root's quarantine stands until an
operator clears it; an
executor that does not export the callback, answers `{:error, :effect_in_flight}`
for a job it still holds or any other error, or returns a receipt that does not
bind to the journaled job leaves the work pending for the host, which then
solicits a fresh query. The lookup is
asked once per activation, runs in a worker under a bound, and never reads
silence as absence. `loopex resume` relies on this: before it, a session whose
process died mid-command resumed into a run nothing would ever settle.

The query is the contract, not a hint. It carries eleven members — the
reconciliation query identity, the current session epoch, the expected executor
identity, the current recovery contract, and the journaled operation, attempt,
canonical request digest, original session and executor epochs, origin executor
identity, and fencing token — and every one must be echoed back unchanged; a
difference names the field that differed. Receipt evidence is then matched
field for field against the job the coordinator journaled. Presence is part of
each comparison: a field the answer or the receipt does not carry is a mismatch,
never a match against an expected value that happens to be absent itself. A query is opened
only where exactly one item sits at `effect_dispatched`; anything else is
`:no_effect_recovery_pending`, and an effect still in flight is
`:effect_in_flight`. Unsolicited evidence is refused rather than admitted.

A model attempt is not reconciled this way. A successor that finds one open
settles it `owner_loss` — charged the run's whole remaining allowance and ended
`failed` — because a provider call is not a Loopex-controlled effect that
reconciliation can complete safely, and its staged bytes are recovery identity
rather than dispatch authority.

Recovery also depends on the Store still holding the log it started with. The
local Store records the log file's device and inode at start-up and re-checks
the path while its append handle is held; a log removed or replaced underneath
it answers `{:log_unavailable, :enoent}` or `{:log_unavailable, :replaced}`,
which is commit-ambiguous like any other append failure, terminates the Store,
and leaves the caller to re-present the exact transaction. Recovery accepts only
a complete checksummed prefix: a strictly torn final frame is truncated away
under a digest taken at read time, while a complete-but-invalid frame refuses to
start at all rather than repairing itself.

### Verification Entry Points

- `mix test` — one application's credential-free suite; the test helpers
  exclude the `real_provider` and `long_bound` tags.
- `mix loopex.deps_budget` — ten-application inventory, roles including
  `:composition`, the admitted external dependencies, and direction.
- `mix loopex.core_only` — core has no adapter resolution or environment-held
  runtime state.
- `mix loopex.docs_check` — compiled public documentation orders Concept before
  Technical depth.
- `mix loopex.status` — governance rows, indexes, links, and bound artifacts.
- `bash scripts/check.sh` — the fast check, which runs the credential-free
  suite one application per VM together with the structural, formatting,
  compilation, dependency, and documentation checks above.
- `bash scripts/check-release.sh` — the slow check: the real-provider
  workflows, the independent Node client, the fresh-source archive build, and
  the `long_bound` proofs in a pass of their own. It reads the provider
  credential from `LOOPEX_PROVIDER_API_KEY`; never put it in argv or in
  retained evidence.

Retained matrix and negative evidence from the milestones that proved these
guarantees are indexed in [docs/evidence](../evidence/README.md).
