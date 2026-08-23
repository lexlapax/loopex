<a id="technical-depth"></a>
## Technical depth

Concept: [Milestone purpose and outcomes](M2.md#concept).

<!-- loopex:plan-technical-envelope:start -->
## Normative Technical Envelope

<a id="technical-plan-prerequisites"></a>
### Prerequisites and Acceptance Points

Concept: [Milestone scope](M2.md#concept-plan-scope).

Concept: [Milestone non-goals](M2.md#concept-plan-non-goals).

These accepted decisions are consumed unchanged and are not reopened:

- **ADR 0001** fixes the repository and application dependency direction.
  Adapter and client applications depend inward on `:loopex`; a client
  application is created only by an accepted plan naming its responsibility.
- **ADR 0002** fixes the OTP 26+/Elixir 1.17+ floor and the two exact validation
  pairs. Core cannot use a language or standard-library feature absent at the
  floor, so `:json` (OTP 27) and `JSON` (Elixir 1.18) are unavailable to every
  application this milestone touches.
- **ADR 0003** fixes the protocol-only contributor boundary. M2 recognises that
  role and creates no extension.
- **ADR 0006** fixes the store transaction contract, commit-time owner-epoch and
  incarnation fencing, transaction resolution, and durable record requirements.
  Every new durable fact this milestone commits — a conversation turn, a tool
  definition generation, an artifact descriptor, a denial, a steer, a
  cancellation — enters through one catalogued production transition.
- **ADR 0007** fixes the trusted-local executor grant, job, receipt, final
  pre-start validation, and independent binding oracle. The four coding tools
  are ordinary jobs under that contract; none of them widens it.
- **ADR 0008** fixes owner-succession recovery and runtime placement. Its
  constraints are load-bearing for Outcomes 9, 10, and 11 and are restated as
  ownership invariants below.

Three decisions must carry recorded acceptance before this plan pair and gate
are accepted and before any implementation begins:

- **ADR 0009 — Tool, executor, and grant contracts.** The loop cannot dispatch
  an effect before the tool definition, job, receipt, grant shape, and the
  `Loopex.Policy` port exist. Outcomes 4, 5, 6, and 8, the tool registry, and
  the attended demonstration depend on it.
- **ADR 0010 — Provider continuation and exact context staging.** A model call
  dispatches only the exact canonical context committed with its intent, turn
  two is a continuation because the committed conversation is replayed rather
  than because a provider handle was retained, and the three declared bounds,
  their accounting, and the fixed project-resource stage are fixed there.
  Outcomes 1, 7, and 8 and the attended demonstration depend on it.
- **ADR 0011 — Session input algebra and streaming progress.** The prompt,
  steer, and follow-up queue semantics and the canonical delta algebra with its
  single durable reconstruction are one decision, because a steer is admitted
  against a run whose current turn is still streaming. It also makes both port
  arity changes this milestone carries. Outcomes 2, 3, 4, 8, and 10 and the
  attended demonstration depend on it.

Deferred decisions and their named acceptance points:

| Deferred decision | Acceptance point |
| --- | --- |
| Context pipeline contracts — registered providers, transformers, selectors, and observers | Before the first registered context provider or extension-contributed transformer exists. M2 implements only the initial local-kernel stage ADR 0010 fixes: canonical history, a fixed reference project-resource stage, trust admission, total budget enforcement, and exact receipts |
| The reference default active-tool profile | After M2's measured prompt cost and task utility. M2 ships `read`, `write`, `edit`, `bash` and measures; it does not fix a reference default |
| Interactive `defer` approval and the mid-run interaction round trip | Before the first surface that can ask an operator a mid-run question. `allow` and `deny` are complete in M2 |
| JSONL RPC framing, DTO vectors, and independent sample clients | The headless session-protocol milestone that follows M2, which is where a wire contract first has a proven client to serve |
| A reference daemon, controller leases, multi-client attachment, and cross-process cancellation | The durable multi-client daemon milestone after that |
| Store selection and migrations | Durable service rung, as the roadmap records |
| Name, trademark, domain, and Hex clearance | Before public packaging, which this milestone does not do |

**Two decisions are disposed by accepting this plan pair itself,** in the way
ADR 0008 was disposed by accepting an existing plan's requirement for it.
Neither is implicit; each is named so acceptance is a decision rather than a
side effect.

**One. A seventh application and a widened client rule.** `apps/loopex_cli` is
added with role `:client`. A `:client` application may declare a production
dependency on `:loopex`, optionally on `:loopex_protocol`, and production
dependencies on the in-umbrella `:edge` applications it composes. It may declare
no external dependency and no dependency on another `:client`. The widening is
required rather than convenient: a shipped composition must name concrete Store,
Model, Executor, Policy, and ArtifactStore implementations to build an
`escript`, core may depend only on the protocol, and an edge may not import a
concrete sibling, so the composition can live only in a client application.
Dependency direction is unchanged — every edge remains inward — and the
composition's reach is bounded by the exact-inspection rule in Ownership below.

**Two. Two narrow ports join the three M1 boundary behaviours.** `Loopex.Policy`
is created by ADR 0009 and required by the founding vision's host policy port;
it replaces the literal `{:host_policy, :allow}` term with `allow/1`, `deny/1`,
and a `defer/1` clause that M2 declares and refuses rather than implements. An
`ArtifactStore` port owns oversized tool output, which the vision assigns to it
and which M2 must produce the moment `bash` runs a real test suite. Each ships
with exactly one local adapter and one reusable conformance suite, inside an
existing application. No third new port, and no generic layer above the five, is
authorized by this acceptance.

**A prerequisite this plan pair names but cannot dispose: an accepted M1 gate
generation.** M1's closed gate binds nine paths by SHA-256, and M2 must change
two of them:

| Bound path | Why M2 must change it |
| --- | --- |
| `apps/loopex/lib/mix/tasks/loopex.deps_budget.ex` | Its planned-inventory constant freezes the repository at exactly six applications with the reference client as the only `:client`. A seventh application fails it, and so does the widened client rule |
| `apps/loopex/test/deps_budget_test.exs` | Its adversarial corpus asserts the M1 inventory and the narrow client rule, and must gain the two cases that prove the M2 inventory and the widened rule |

Those digests are not enforced only by `scripts/check-m1-gate.sh`.
`Mix.Tasks.Loopex.Status` verifies every plan's declared bound artifacts against
the current working tree on every invocation, and its history pass repeats that
at every revision reachable from `HEAD`. Neither exempts a `Closed` milestone.
The observable consequence of changing either file without an accepted
amendment, at that same revision, is:

```text
** (Mix) docs/plans/M1-gate.md: bound artifact apps/loopex/lib/mix/tasks/loopex.deps_budget.ex does not match its locked digest
```

That failure propagates. `mix loopex.status` and `bash scripts/check-bootstrap.sh`
are both locked M2 gate commands, bootstrap runs the status check, and
`scripts/check-m0-gate.sh` runs bootstrap, so the closed M0 gate goes red
transitively. Rebinding the digest outside the governed path does not help
either: a completed gate governance record is immutable, and the retained
Acceptance row still names the prior bytes, so binding validation refuses the
edit rather than adopting it.

**M1 is `Closed`, so the ordinary amendment cannot reach it.** Its Acceptance
row and its Closure row both bind gate
`sha256:bfc61ad1441f997ad81dbb10bd44396a6c8912d2a996cba8c3a896ada0f4e58b`. The
`amendment-transaction-v1` transaction rebinds Acceptance alone, which would
leave M1's Closure row naming bytes that no longer exist, and no later revision
returns the plan to a valid state. The conforming path is the additive
transaction marked `amendment-transaction-v2`: a new gate generation appended to
the closed plan, with both authority rows left byte-immutable. Its shape is
fixed here so acceptance sees its whole cost:

- **Decision owner.** The maintainer. This is a baseline exception against a
  closed, immutable gate and is explicitly non-delegable. Accepting the M2 plan
  pair does not imply it, authorize it, or schedule it.
- **What changes in `docs/plans/M1.md`.** Nothing inside either authority row.
  The plan gains one `## Gate Generations` table outside both envelopes, and the
  amendment appends one row to it carrying the next consecutive generation
  number, the accepting authority, durable evidence of that authority's explicit
  disposition, the candidate SHA, and the new gate digest. The table is
  append-only; an existing row is never rewritten, and neither authority row is
  ever made retroactively false.
- **Rejoin position.** Proposal `A` is the same revision as the workstream E
  commit that changes those two files. Not the successor of it: artifact
  validation judges every reachable revision against the generation current at
  that revision, so a revision that changes a bound artifact without carrying
  its generation row fails at every descendant forever, and no later generation
  heals it. It cannot land earlier either, because at `A` the amended gate must
  be proved against a tree that already carries the M2 bytes it rebinds.
- **Transaction.** `A` is one atomic revision. It carries the amended M1 gate
  document, its new generation row with an empty authority and evidence, and
  both rebound artifacts together. Splitting the artifact change from the
  generation row across two revisions permanently invalidates history and is not
  a recoverable mistake. After exact-SHA review and explicit acceptance, the
  immediate child `R` completes only that row's authority and evidence. Only `R`
  is integration-eligible.
- **The declared truthful reproof.** The amendment must state, and its proposal
  must demonstrate, what `bash scripts/check-m1-gate.sh` actually reports at an
  M2 revision. M1's retained matrix names an M1 source candidate, and the M2
  tree differs from it by product bytes, so M1's own gate is red there for that
  stated reason at both `A` and `R`. The amendment declares that exact state
  rather than claiming a green M1 gate on an M2 tree. M1's gate is not an
  inherited required gate for M2: M2 inherits M0 and re-runs M1's protected
  selectors behaviourally, which is what the Inherited section of the M2 gate
  exists to do.
- **The alternative, and why this plan does not recommend it.** The enforcement
  could instead be changed so the status check exempts a `Closed` milestone's
  bound artifacts. That is one edit instead of a transaction, and it is worse:
  it silently retires digest protection for every closed gate, forever, to avoid
  one named exception. It is also portable-enforcement weakening and therefore
  equally non-delegable. The generation keeps the protection, keeps every
  earlier generation governing the revisions it covered, and pays only for the
  change it needs.

Until `R` is accepted and integrated, M0, the bootstrap aggregate, and the
status check are red, and no M2 product checkpoint that changes those two files
is an integration candidate. A gate generation adds no scope, changes no M1
outcome, and reopens no lifecycle state.

**Implementation constraints fixed by consuming those decisions.** These are how
the outcomes get built. None of them is an operator capability, and none may be
traded away to make an outcome easier.

**The tool registry is a mechanism, not a feature.** An operator asks for
working tools and a loop that keeps going; nobody asks for a registry. It exists
because Outcomes 1 and 4 both need one name to resolve to exactly one
implementation, and it is runtime-scoped read-mostly data plus resolution rules
inside core. It defines no behaviour module, no callback, and no replaceable
implementation, and it registers no global name, application-environment value,
or persistent term. Its constraints are:

- A tool's durable identity is the triple of `tool_id`, `tool_version`, and the
  digest of its canonical definition bytes — its **definition generation**.
- The model-visible name is what a provider call actually names, so a session
  commits one name-to-generation mapping together with its active set at start,
  and every call in that run resolves through that one mapping. Two active
  generations claiming one name refuse session start as a conflict rather than
  being ordered, preferred, aliased, or silently renamed.
- Every tool call records the generation it resolved, and a registry change
  cannot alter an in-flight operation's semantics.
- A runtime's active tool set is named explicitly in its configuration. Two
  runtimes in one VM carry independent registries.

**A staged request stands on its own.** Following ADR 0010, a staged request
carries the complete canonical tool-definition bytes — name, description, and
parameter schema — alongside the generation triple, so the exact request a turn
dispatched is reconstructible and independently verifiable from the journal
alone, with no registry lookup and no dependence on mutable state. The reserved
continuation field is present in the canonical projection and empty in every M2
request: what this milestone builds is canonical-history replay, and no code,
document, or evidence record may describe it as provider-native continuation.

**Bounds are enforced where they can actually bind.** The run's committed
absolute deadline instant is propagated into the supervised model call rather
than checked only between turns, and there is no independent per-call timeout to
disagree with it. The completion race is decided by committed journal order: a
reply that commits before the abort is admitted completes that turn and its
assistant message is canonical history, while an abort admitted first commits no
assistant message and keeps the late reply as attempt evidence only. A cancelled
or deadline-aborted turn is charged its request bytes plus that turn's committed
`max_tokens` in full, marked `estimated`, because observed output counts do not
survive restart and charging zero would make aborting every turn the cheapest
way to stay inside a budget. Reaching a bound commits `bound_reached`, the
terminal outcome the vision added for exactly this ending, carrying the bound,
the observed value, and the accounting source. It is never recorded as a failure:
nothing malfunctioned, the committed conversation is complete, and a later run
continues it under a new bound.

**Two sequence domains, never one.** Following ADR 0011, `model_sequence` is per
model attempt and is closed by the reply's `delta_count`; `progress_sequence` is
per `(operation_id, attempt)` and is closed by the receipt's additive private
`final_progress_sequence`. Each domain closes itself on the transient plane with
a content-free item — `model_stream_closed` and `tool_stream_closed` — because
neither closing total may sit on a durable element. The executor boundary change
is exactly one parameter: `execute/4` becomes `execute/5`, gaining a bounded
in-VM progress function in the trailing position. Grants, job request, receipt
schema apart from that one private field, deduplication, cancellation, and the
terminal algebra are untouched, and an executor that emits nothing is conformant.
Executor progress carries the full identity, epoch, digest, and fence tuple, and
the coordinator validates every binding fail-closed against state it already
holds for the live attempt before any narrower client DTO is projected. A refused
event is dropped and counted on the attempt's private record; it is never
projected, journaled, published, or allowed to affect an outcome.

**Stopping is reported, not promised.** A run finishes `cancelled` only where
every owned operation reached a validated terminal fact and every owned process
tree was confirmed cleaned. Anything less finishes `outcome_unknown` carrying the
reconciliation reference of the operation that could not be proved. No document,
help text, or transcript this milestone ships says an interrupt always ends a run
cleanly.

**Every executor-backed tool needs a decision.** Policy is consulted for every
executor-backed tool including a `read_only` one; there is no read-only
exemption. Starting a runtime with an executor-backed tool active and no named
policy is refused rather than defaulted.

**The four inputs are four affordances.** The runtime never guesses which input
class an input is, so the command surface must not guess either. `prompt`,
`steer`, `follow_up`, and `abort` each get a distinct explicit affordance, and
input naming neither steer nor follow-up is refused rather than resolved from
the state of the session. A steer is recorded applied only when a committed
request actually carried it.

**A spilled artifact has an operator path.** Outcome 5's retrieval is a real
command — `loopex artifact <reference>` — projecting the same `ArtifactStore`
port an embedder calls. The reference stays opaque; it is not a filesystem path
the model can steer, and the command resolves it through the port rather than by
reading the adapter's storage layout. The operator documentation states plainly
that the local adapter stores artifact bytes and session records unencrypted on
the local disk under the resolved state root.

**Each reference host names its own permissive policy.** ADR 0009 places
`Loopex.Policy.AllowAll` in `loopex_reference_client`, and a `:client` may not
depend on another `:client`, so `loopex_cli` cannot reach that module and does
not try to. It ships its own named permissive policy for a trusted local
developer, selected only when the operator passes the corresponding `--policy`
value, and emitting the same single permissive-authority notice. Two reference
hosts each making their own decision is the ownership the ADR describes; one
host importing the other's would be the relocation of authority it forbids.

Accepting this plan pair authorizes only the eleven outcomes, the tool registry
and attended demonstration that support them, and the five named boundary
behaviours. Any further deferral, gate weakening, evidence waiver, sixth
boundary behaviour, new persistence decision, external dependency, publication,
or public compatibility claim requires its ordinary explicit disposition.

<a id="technical-plan-ownership"></a>
### Ownership, Decision Owners, and Rejoin Barriers

Concept: [Milestone scope](M2.md#concept-plan-scope).

One integrator owns rejoin, conflicts, the candidate SHA, and post-rejoin
verification. The maintainer owns plan and gate acceptance, the M1 gate
amendment above, scope deferral, gate weakening, evidence waiver,
blocking-finding disposition, closure, and every decision class the development
contract reserves.

**Session truth stays where M1 put it.** The session coordinator remains the
sole serial writer of its session's durable truth. The tool registry is
runtime-scoped read-mostly data reached through the explicit runtime reference;
it registers no global name and stores no session state. The model adapter, the
artifact store, the policy implementation, and the executor return evidence;
none of them mutates session truth or publishes a durable fact. Conversation
history is a projection of committed durable records, never a second store: a
turn is not part of the conversation until its record commits.

**Deltas are not truth.** A streamed text, reasoning, tool-call, or
tool-progress delta is transient progress on the progress plane. Exactly one
reconstructed assistant message per turn becomes durable, and it becomes durable
before its stable public event. No delta is journaled, replayed, or projected; a
reconnecting or resuming caller sees the committed message, never a partial one.
A stream that ends without a complete message commits nothing, and the turn
fails truthfully.

**The command surface owns nothing durable.** `loopex_cli` calls only the public
`Loopex` facade for every session operation, including the interrupt path.
Exactly one module in that application — the shipped composition — may name
concrete Store, Model, Executor, Policy, and ArtifactStore implementations, and
it may do so only to build the runtime options passed to `Loopex.start_link/1`.
No other module in the application may reference a coordinator, journal, outbox,
store, adapter, executor, policy, or artifact-store module, hold a cursor as
truth, or make an authority decision. The gate proves this by source inspection,
exactly as M1 proved it for the reference client.

**Cancellation is same-process by construction.** The foreground command traps
the interrupt signal and calls the public abort operation on the session it is
running. It does not signal another process, write a control file, or open a
channel. `loopex cancel <session>` is a distinct, narrower operation: it applies
only where no live Runtime Control holds the session's placement key, acquires
ownership through a fresh resume command identity under the session's durable
`runtime_id`, and drives the session from durable evidence to `cancelled` or
`outcome_unknown`. Against a live owner it is refused by ADR 0008 mutual
exclusion with an explicit message, and that refusal is a locked case rather
than an accident.

**ADR 0008 placement is an invariant of the operator experience, not a detail.**
The command surface must obey all four consequences:

1. A session is permanently bound to the `runtime_id` that created it. Resume
   through a different `runtime_id` is refused, and the refusal is reported to
   the operator in words that say what to do.
2. `runtime_id` is durable placement identity that must be re-presented after
   restart. A command that generates a fresh random `runtime_id` per invocation
   strands every session it created. The command surface therefore persists its
   placement identity in the resolved state root and re-presents it.
3. Once a create or resume command completes, re-presenting the same
   `command_id` returns the historical result without advancing the owner epoch.
   Acquiring a live replacement owner requires a fresh unique `command_id`; a
   deterministic `resume-<session_id>` would return a stale result and never
   acquire ownership.
4. Loopex provides no VM-global lock, so the host owns mutual exclusion of
   Runtime Controls on one `(Store identity, runtime_id)` placement key. The
   command surface owns that exclusion for its own state root and fails closed
   with an explicit message when it cannot acquire it, rather than starting a
   second Control.

Rejoin barriers are serial and exact:

1. **A — Tool contract and registry rejoins first.** The tool definition shape
   in `loopex_protocol` and the runtime-scoped registry in core are integrated
   before any caller names a tool.
2. **B — Loop, bounds, streaming, input algebra, and staging rejoins second.**
   The turn machine, canonical history projection, per-turn exact staging, the
   three declared bounds, the delta algebra, the input queue, and the
   project-resource stage build on A. No tool implementation is integrated
   before B proves a turn dispatches only its committed bytes.

   B also owns both port arity changes, because no other workstream owns either
   and each touches every implementation at once. ADR 0011 makes `complete/2`
   into `complete/3`, which reaches three inherited M1 roles: 5a
   `real_model_lane_test.exs`, and the real-provider roles 5b and 5c on
   `real_model_session_test.exs`. The same decision makes `execute/4` into
   `execute/5`, adding one bounded in-VM progress function in the trailing
   position and nothing else, which reaches inherited role 6 on
   `executor_test.exs` and both combined real-provider roles. None of those
   files is a bound artifact, so their bytes may change, but their locked case
   names and asserted behaviour are reproduced exactly at M1's identities and
   states. B carries the migration of the deterministic adapter, the ReqLLM
   adapter, the trusted-local executor, and every affected role in one rejoin
   rather than leaving it to whichever workstream trips over it, and it re-runs
   5b, 5c, and 6 under the credential rule before C begins. An implementation
   that emits no progress through either new parameter stays conformant, so the
   arity change is not a behaviour change for an adapter that does not stream.
3. **C — Coding tools, artifacts, and host policy rejoins third.**
   `loopex_executor_local` implements the four tools against A's contract, emits
   validated executor progress through B's new parameter, and gains the `deny`
   path and owned-process termination; `loopex_store_local` gains the
   artifact-store adapter; and `loopex_reference_client` gains the shipped
   permissive policy and its own lane. No edge imports a concrete sibling
   adapter, and no application depends on a `:client`.
4. **D — Cancellation and the session directory rejoins fourth.** Cancellation
   needs C's termination evidence and B's turn machine. The session directory
   needs the resolved state root and ADR 0008 placement identity.
5. **E — Operator surface and demonstration rejoins last.** `loopex_cli` builds
   only on the integrated A–D paths through the public facade. Its first commit
   carries the seventh-application inventory change, and the M1 gate generation
   above lands with it. A private client loop, substitute store, fake provider,
   or bypass executor is not a demonstration of this milestone.

Core is a serial ownership chain across A, B, and D rather than parallel
writers, because those workstreams touch the same coordinator and session-state
modules. Parallel writing is confined to the pairs that own disjoint
applications. Every parallel writer uses non-overlapping file ownership,
separate branches or checkpoints, separate worktrees, and isolated build,
dependency, and state roots. No workstream creates an alternate durability
truth, authority path, or session loop to avoid a barrier.

<a id="technical-plan-evidence"></a>
### Evidence Obligations and Mapping

Concept: [Milestone outcomes](M2.md#concept-plan-outcomes).

The outcome selectors are necessary but not separable substitutes for the
Purpose.

**Mandatory closure evidence.** Closure requires one retained attended
demonstration in which a real provider drives the shipped `loopex` command
through a genuine multi-tool coding task in a real Git repository, using the same
product runtime, store, model, executor, policy, artifact store, tool registry,
embedded API, and command code the focused selectors exercise. It is not an
outcome, because it is not a capability an operator asks for; it is the evidence
that the eleven outcomes add up to a coding agent rather than to eleven passing
selectors. That makes it more binding, not less: an outcome can in principle be
dispositioned as an approved limitation, whereas this obligation is what closure
means here. A closure candidate without it is refused, deterministic tests are
supporting coverage that cannot stand in for it, and the gate locks both its
selector roles and its real-provider profile exactly as it locks an outcome's.

Its retained record is `docs/evidence/M2-coding-demonstration.md`. The
demonstration must complete a task requiring at least three turns and at least
three distinct tools including one `edit` and one `bash`; count turns, tool
calls, and effects outside the runtime; prove the answer was streamed and
reconstructed once per turn; include one host-policy refusal that the transcript
reports while the task continues truthfully; prove the resulting file bytes on
disk; and retain non-secret provider, model, endpoint, adapter, executor, and
tool identity from the successful role through the bound runner's sealed
`combined` profile. A zero-executed, skipped, or credential-free run cannot
satisfy it. The disposable Git repository it works in is created inside the
gate's own task root and is never the operator's own repository.

Every protected selector runs through the bound `scripts/m1-exunit-runner.exs`,
invoked directly with `elixir` outside every product application, exactly as M1
proved. The script starts and configures ExUnit itself, dispatches no Mix task
or alias, and loads no `test_helper.exs`. It receives the exact invocation role,
selector path, seed, minimum, exclusion policy, and expected test identity and
state. Official ExUnit results, rather than test-owned stdout, must show every
locked name in the required state, the locked minimum, and no unaccounted skip,
exclusion, filter, quarantine, pending case, setup failure, or test failure. M2
reuses that channel rather than building a second one, and reuses its
`LOOPEX_M1_SELECTOR_V1` nonce frame as the only path a provider credential takes
into a selector VM.

That script is bound at exactly the bytes M1 closed with, so its retained
real-path identity contract is fixed rather than negotiable. Its `model` profile
seals provider, model, endpoint, and adapter build; its `combined` profile seals
those plus executor build, executor identity, and tool identity; and both refuse
a report whose key set differs, whose adapter build is not
`loopex_llm_reqllm@0.0.0`, or whose executor build is not
`loopex_executor_local@0.0.0`. M2 keeps `VERSION` at `0.0.0`, so those literals
hold. No additional field can enter a sealed real-path report without changing
an immutable artifact, which is why the provider-reported input-token count in
the prompt budget below is retained evidence for review rather than a second
gate-enforced ceiling.

The ordinary full suite and every credential-free control remain
credential-free. The gate runner refuses `LOOPEX_PROVIDER_API_KEY` in its
initial environment and accepts an optional credential only through a bounded
`LOOPEX_M2_PROVIDER_V1` stdin frame, held in one unexported holder and forwarded
only to the explicitly tagged real-provider roles. Absence is evidence
unavailable and fails those roles rather than skipping them. Gate-owned output
is compared against the literal key before emission. This is containment at the
runner boundary; M2 does not rebuild M1's sealed-environment apparatus and makes
no claim to defend against a hostile already-running shell.

Outcome-specific obligations are:

| # | Obligation |
| --- | --- |
| 1 | Generate legal multi-turn histories and prove the run continues while the model requests tools and ends when it does not; prove every request after the first contains the original prompt, the model's own prior assistant message including its tool call, and the real tool result rather than a synthesized string; prove the canonical request bytes and digest committed before each dispatch are exactly the bytes the adapter receives; prove a staged request carries complete canonical tool-definition bytes and its generation triple and is reconstructible and verifiable from the journal alone; prove every turn after the first is canonical-history replay and that the reserved continuation field is present and empty; prove each of the maximum-turn, cumulative-token, and wall-clock bounds is evaluated before staging, commits `bound_reached` naming the bound and the observed value, with the accounting source retained beside it, costs no provider call, and fabricates no assistant message; prove the committed absolute deadline is propagated into the supervised model call rather than duplicated as an independent per-call timeout; prove the completion race is decided by committed journal order, so a reply committing first completes the turn and an abort admitted first commits no assistant message and retains the late reply as attempt evidence only; prove a cancelled or deadline-aborted turn is charged its request bytes plus that turn's committed `max_tokens` in full and marked `estimated`; prove `max_tokens` and every other sampling bound is a declared committed value with no implicit fallback anywhere in the path; assert complete derived fault coverage over every new durable transition |
| 2 | Run one shared streaming conformance suite over every model adapter; prove each of the four canonical delta kinds is bounded plain data carrying no provider struct, pid, function, module atom, exception, terminal escape, or credential; prove a text delta is observable by a consumer while the operation that produces it is still incomplete, so an adapter that buffers a whole answer and emits every delta immediately before returning fails rather than passes; prove replaying an adapter's emitted deltas in order reproduces byte-identical content to the reply it returned; prove `model_sequence` and `progress_sequence` are separate domains, each gapless and monotonic from zero, closed respectively by the reply's `delta_count` and the receipt's `final_progress_sequence`, each announced on the transient plane by its own content-free `model_stream_closed` or `tool_stream_closed` item, and that neither closing total sits on a durable element; prove the counts make coalescing, dropping, or a truncated tail detectable rather than silent; prove the committed assistant message is built from the adapter's return value and never assembled from deltas, and that no delta is journaled, published as a durable event, or replayed on reconnect; prove a cancelled stream commits no `assistant_message` element at all and that a late reply for an aborted attempt is retained truthfully and never becomes canonical; prove an adapter that emits no deltas is conformant and declares that it does not stream |
| 3 | Prove a prompt is admitted only while the session is settled and is refused with an explicit reason while a run is active; prove a steer names one active run, that a steer naming a different run or naming none while a run is active is rejected rather than retargeted, and that the runtime never infers which input class an input is; prove an admitted steer is applied after the current tool batch completes and before the next model request is staged, commits as a user-role conversation element in admission order, and does not attempt to reverse an effect already started; prove a steer is recorded applied only when a committed request actually carried it, so a steer admitted against a run that never staged another request is never reported as applied; prove a follow-up is queued and starts a new run only after the active run and its steering settle; prove a steer whose run reaches a terminal outcome first commits as unapplied with its reason rather than being discarded or promoted; prove at most one unapplied steer per run and at most one queued follow-up exist, and that both queue states are durable and survive owner succession; prove a durably admitted abort resolves any unapplied steer and any queued follow-up as cancelled |
| 4 | Run one shared conformance suite over `read`, `write`, `edit`, and `bash`, covering bounded and truncation-reporting output, workspace-root resolution, refusal of every path that escapes the root through traversal, a symlink, or a link chain, exact edit preconditions with a mismatch diagnostic that names what differed, explicit shell-versus-argv semantics, and ownership and termination of the whole child process tree; each tool executes as a real controlled OS process under ADR 0007 with a credential-free environment; prove an emitted executor progress event carries the complete identity, operation and attempt, session, executor and origin epochs, canonical request digest, and fencing token, that each binding is validated fail-closed against state the coordinator already holds rather than against the event, that a missing binding and a present-but-wrong binding are refused identically, and that a refused event is dropped and counted on the attempt's private record without ever being projected, journaled, published, or allowed to affect an outcome, bound, or receipt |
| 5 | Run one reusable `ArtifactStore` conformance suite over the local adapter, covering put, get, absent, and repeated-digest cases; prove output beyond a tool's declared bound spills to an artifact rather than truncating silently, that the durable event carries content digest, media type, size, logical role, and an opaque retrieval reference, and that the reference is opaque rather than a filesystem path the model can steer; prove the model-facing result stays under its bound and names what was truncated; prove the artifact round-trips byte-exactly and that a corrupted or missing artifact is reported as unavailable rather than as empty content; prove the operator retrieves a spilled artifact by that opaque reference through the public facade, resolved through the port rather than by reading the adapter's storage layout |
| 6 | Run one reusable policy-port conformance suite; prove a `deny` decision issues no grant, that no operating-system process starts, and that the refusal is a committed durable fact the operator can read; prove the run continues or terminates truthfully after a denial and never retries the refused call; prove a policy that raises, times out, or returns a malformed value fails closed into denial rather than falling through to allow; prove `defer` is declared and refused in M2 rather than silently treated as allow or deny; prove every executor-backed tool including a `read_only` one requires a decision and that there is no read-only exemption; prove model output, tool metadata, IDs, injected context, and ordinary client input cannot mint or widen a grant; prove with the selector's own in-file fixture policies that a permissive policy applies only when it is named in configuration and that omitting the policy option refuses runtime start rather than falling back to permission, importing nothing from any client; separately, in the reference client's own lane, prove the shipped `Loopex.Policy.AllowAll` allows every decision it is asked and emits exactly one visible permissive-authority notice |
| 7 | Prove discovery resolves a deterministic canonical ordered resource set for a workspace, that the order is stable across platforms and filesystem enumeration order, and that a per-path, per-file-size, or total-size limit refuses the excess resource explicitly rather than silently dropping it; prove the operator is presented every resolved path, its provenance class, its trust class, and the manifest digest before deciding; prove a positive decision binds canonical workspace identity, revision, resolved set, and digests, and that changing any of them invalidates it and requires a new decision; prove a headless run with no matching positive decision fails closed and stages no project block; prove an admitted block changes no active tool set, policy decision, declared bound, or grant, and that typed delimiters are input structure rather than an authority boundary; prove an ordinary workspace read requested by the model stays a policy-governed tool effect and never enters the staged project block, so the staging path covers only behaviour-shaping resources proactively admitted by an operator decision; prove the staging receipt records the final ordered block descriptors |
| 8 | Prove cancellation is the acknowledged protocol: the request is durably recorded, scheduling stops, the in-flight model call and executor job receive a cooperative cancel, a bounded grace period elapses, and the owned process tree is terminated; prove `cancelled` commits only where every operation the run owned reached a validated terminal fact and every owned process tree was confirmed cleaned, and that any weaker state commits `outcome_unknown` carrying the reconciliation reference of the operation that could not be proved; prove the interrupt path reaches the run through the public facade and through no private path; prove a validated terminal tool fact that committed before the abort is preserved and is not overwritten by `cancelled`; prove insufficient effect evidence commits immutable `outcome_unknown` with no blind retry; prove an aborted model response never becomes a canonical assistant message; prove a second interrupt reports what is still being cleaned up rather than abandoning the session; prove the operator observes both what was cancelled and what actually happened |
| 9 | List sessions from a state root resolved from `LOOPEX_HOME` in a fresh operating-system process with no inherited runtime; prove the state root is never read from application environment; prove a session resumes under its creating `runtime_id`, that a different `runtime_id` is refused with an explicit reason, that a repeated resume command identity returns its historical result without advancing the owner epoch, and that a fresh identity acquires live ownership; prove the placement identity survives restart because it is persisted and re-presented rather than regenerated |
| 10 | Drive `run`, `sessions`, `resume`, `cancel`, and `artifact` end to end through the embedded API; prove `prompt`, `steer`, `follow_up`, and `abort` each have a distinct explicit affordance, that the operator steers a running task and queues a follow-up from the same terminal, and that input naming neither steer nor follow-up is refused rather than resolved from session state; prove tool progress emitted by a running executor job reaches the operator's terminal before that tool finishes; prove `artifact` retrieves a spilled artifact by its opaque reference; deliver a real interrupt signal to a real running command process and prove the task is cancelled through the public facade, that what was observed is printed, and that an interrupt whose cleanup cannot be confirmed reports `outcome_unknown` with its reconciliation reference rather than a clean `cancelled`; prove `cancel` against a live owner is refused by placement mutual exclusion with an explicit message and that against a dead owner it reconciles the session to a truthful terminal state; prove `--policy` selects the governing host policy and that a run under a refusing policy reports the refusal and continues or terminates truthfully; prove the project-resource trust decision is presented and taken at the terminal and that a non-interactive invocation without a matching decision fails closed; replace or instrument the facade so the test fails if any module outside the single shipped composition reaches a coordinator, store, model, executor, policy, artifact store, journal, outbox, or cursor internal or owns a second state machine; measure the base system prompt plus active tool definitions with the documented deterministic estimator and require the result under one thousand tokens before project context; prove argument parsing and terminal output use only the standard library and that the application declares no external dependency; prove no wire or line-framing contract is introduced |
| 11 | Start the OTP application tree, a runtime, and a session, submit a prompt, and consume events using only the shipped composition module; measure that module and require at most eighty effective lines, counting neither blank lines nor comments; prove the `loopex` command uses that same composition rather than a second one; prove the composition resolves its state root explicitly and reads none from application environment |

The tool registry carries its own obligation beside the outcomes it serves:
resolve a tool by ID and version through a runtime-scoped registry; refuse an
unknown ID and refuse a conflicting registration with an explicit reason; prove
two runtimes in one VM carry independent registries and that no global
registration, application-environment value, or persistent term supplies one;
prove a session commits one model-visible-name-to-generation mapping with its
active set at start and refuses session start when two active generations claim
one name, rather than ordering, preferring, aliasing, or silently renaming them;
prove each model request records the exact definition generation used, and that
an in-flight operation's semantics cannot change because the registry changed.

Durable fault coverage stays structural, as M1 established. Every new logical
operation that can change durable session truth enters through one production
transaction dispatch, every executable transition phase carries a stable
`fault_point_id`, and evidence asserts set equality between the complete
declared, injected, and observed `{transition_id, fault_point_id}` key sets. A
new production transition without a derived injected and observed case fails
that equality assertion rather than silently escaping the catalogue.

Required mutation evidence is eight ordered, independently restored records in
`docs/evidence/M2-negative-demonstrations.md`. Each starts from its own named
clean candidate, identifies the exact tracked path and candidate blob digest,
disables only that mechanism, runs the named protected selector that must fail
for the named reason, restores the artifact from `git show <candidate>:<path>`,
and records the restored SHA-256, which the gate compares against the current
tracked bytes:

1. Outcome 1 / `committed_history_projection` /
   `apps/loopex/test/agent_loop_test.exs`
2. Outcome 2 / `stream_delta_reconstruction` /
   `apps/loopex_llm_reqllm/test/streaming_conformance_test.exs`
3. Tool registry / `tool_definition_generation_binding` /
   `apps/loopex/test/tool_registry_test.exs`
4. Outcome 4 / `workspace_path_scope_containment` /
   `apps/loopex_executor_local/test/coding_tools_test.exs`
5. Outcome 6 / `host_policy_deny_prestart_refusal` /
   `apps/loopex_executor_local/test/host_policy_test.exs`
6. Outcome 7 / `project_resource_trust_admission` /
   `apps/loopex/test/project_resource_trust_test.exs`
7. Outcome 8 / `cancellation_cleanup_confirmation` /
   `apps/loopex/test/cancellation_test.exs`
8. Outcome 10 / `command_surface_facade_only` /
   `apps/loopex_cli/test/cli_test.exs`

The last record covers the milestone's headline structural claim. Introducing a
client application is exactly when "session before surface" is most at risk, so
the mechanism that fails a build where a second module reaches past the facade
carries a mutation record of its own rather than resting on source inspection
alone. No record stands in for two mechanisms, and a failure observed from a
dirty or previously mutated baseline is no evidence.

Execution evidence has three non-self-referential full M2 captures — Darwin at
the exact floor pair, Darwin at the exact current pair, and Linux at the exact
current pair — plus one exact-candidate re-proof of the immutable M0 gate on
each locked pair. Each capture starts from the same clean committed source
candidate `C`, runs the complete captured M2 command set except validation of
the record it is about to create, and emits one authoritative non-gate `CAPTURE`
record only after those commands pass. A capture never calls the ordinary gate
recursively, emits GREEN, or supplies merge evidence. Every capture and M0
re-proof uses fresh, disjoint build, dependency, temporary, `LOOPEX_HOME`,
workspace, and product-state roots; physical order and adjacency are inert.

The three captures and the attended demonstration record are committed in
evidence commit `E`, the direct one-parent child of `C`. `C→E` may change
exactly `docs/evidence/M2-toolchain-matrix.md`,
`docs/evidence/M2-negative-demonstrations.md`, and
`docs/evidence/M2-coding-demonstration.md`; every other tree byte is identical.
The ordinary gate runs at `E` on all three lanes and alone may emit final GREEN.
Closure transition `T` is the unique commit that first completes M2's canonical
Closure record and is the direct one-parent child of `E`.

Mechanical and judgment authority stay separate, and the gate document
enumerates exactly what the runner checks so no reader infers more:

| Authority | Owns |
| --- | --- |
| `bash scripts/check-m2-gate.sh` | Bound artifact digests, protected and inherited selector identities, states and minima, locked command exit status, the matrix marker set, its single reachable candidate, its per-lane toolchain and platform fields, its cross-lane identity agreement, its four self-describing digests against the files they name, negative-demonstration record shape, key order, selector pairing, tracked-path safety, and each restored digest against current bytes, the credential boundary, and user-state containment |
| `mix loopex.status` | Live consistency among M2's governance rows, register state, root README status capsule, indexes, links, and the current revision's lifecycle claims, and every plan's declared bound artifacts against the working tree and reachable history |
| Independent review | Whether tests assert what their names promise, whether mutations, interrupts, and cancellations were honestly injected, whether one clean-baseline mechanism was disabled and caused each named failure, whether retained fields match actual captured process output, whether the attended demonstration was a genuine task rather than a scripted one, whether the provider-reported input-token count agrees with the estimator, whether the closure documents are current, and whether the operator experience satisfies the Purpose |

One canonical decimal gate seed from `0` through `999999` is supplied to every
M2 protected selector role, every inherited M1 selector role, the provider
default-exclusion control, and the ordinary final full suite in that gate run.
`protected_executed` is the sum of authoritative executed test counts across
M2's own locked roles — the eleven Outcomes, the supporting tool-registry role,
and the attended demonstration's two roles; a test reported excluded never
counts, and inherited, mechanics, bootstrap, and full-suite executions are
excluded from that sum.

<a id="technical-plan-compatibility"></a>
### Compatibility

Concept: [Milestone scope](M2.md#concept-plan-scope).

No public contract, protocol, storage format, package, or version is frozen,
labelled for release, or given a compatibility promise. `VERSION` stays `0.0.0`,
nothing is tagged, and the vision's seventh compatibility surface — released
package names, their contents, and the constraints they declare — stays inert
because nothing is published.

Every surface M2 touches is therefore unstable and may change without notice
until a milestone publishes one: the embedded Elixir API, the `loopex` command
surface, the private journal and store schema, the executor job and receipt
protocol, the tool contract, the policy port, and the artifact-store port.
`docs/developer/compatibility-surfaces.md` records that list and says plainly
that no label, deprecation window, or migration note is owed for any of them
yet. Internal process topology, process messages, and private structs are not
public API. No surface becomes a release candidate here, because none of them
has schemas, independent consumers, vectors, or migration evidence.

The private journal and store schema changes in this milestone: conversation
turns, tool definition generations, artifact descriptors, denials, steers,
follow-ups, and cancellations are new durable records. A session data root
written by an M1-era revision is therefore not readable by M2. That is stated
plainly in the operator documentation rather than worked around, because M1
accepted no installed-store compatibility contract and M2 accepts none either.

Milestone execution remains portable across the three locked lanes: Darwin
floor, Darwin current, and Linux current. Each lane runs the same source, gate
runner, protected selectors, inherited selectors, credential-free suite,
real-provider roles, coding tools, and demonstration. The floor lane is the
binding constraint on implementation technique, not a reduced smoke test: with
neither `:json` nor `JSON` available there, any JSON encoding or decoding this
milestone needs is repository-owned code proved on that lane. The Linux lane
demonstrates runnability at the current pair without asserting a floor-on-Linux
result or a permanent public support matrix.

<a id="technical-plan-migration"></a>
### Migration and Rollback

Concept: [Milestone scope](M2.md#concept-plan-scope).

There is no installed base and no released artifact. M0 and M1 journals and
retained evidence are not migrated; M2 tests, demonstrations, and gate runs
create isolated M2 data roots. No PostgreSQL, SQLite, or other external store
migration is claimed. No tag is created, so there is no tag to roll back.

Before M2 first becomes green, every product checkpoint offered for review keeps
the bootstrap aggregate and both exact M0 lanes green while the M2 runner
reaches its next truthful missing-feature red. The single declared exception is
the M1 gate generation window named in Prerequisites: from the workstream E
commit that changes the two bound artifacts until generation revision `R` is
accepted and integrated, bootstrap, the status check, and the M0 gate are red
for that one stated reason, and no checkpoint inside that window is an
integration candidate. The window closes because `R` lands, never because a
waiver excuses it.

The accepted opening checkpoint is the complete repository rollback target for
unintegrated M2 product work: reverting the designated milestone branch to it
restores the accepted red condition without rewriting durable user data. After a
complete M2 candidate first becomes green, each later checkpoint must keep M2
and both M0 lanes green or be reverted to the last reviewed green checkpoint.
Ordinary local red-green work between checkpoints is not an integration
candidate.

The accepted governance checkpoint is the one integration exception before M2
closure. After its exact transition is independently reviewed and the maintainer
separately approves the protected-branch merge, the accepted plan and gate
machinery, governance, derived status and documentation, and portable
enforcement may integrate to `main` while the exact accepted opening gate
remains red. That surface contains no M2 product implementation bytes; `main`'s
product baseline therefore remains M1. The designated M2 branch stays live
because it owns the unintegrated product work through closure.

An accepted-plan amendment is not a source candidate `C`. M2 is not `Closed`
while it is being implemented, so an amendment to this plan pair uses the
generic direct one-parent proposal and rebind transaction declared by the
`amendment-transaction-v1` marker in the gate. Proposal `A` is the first
revision to advance the generation and retains the prior Acceptance row and
lifecycle state, so binding validation, bootstrap, and any inherited gate that
invokes them must fail there only for the stale binding, while
binding-independent checks and the M2 runner's truthful product state are proved
directly at `A`. Its immediate child `R` rebinds Acceptance to exact `A`, adds
one new amendment-specific disposition anchor to an existing durable document,
and changes no envelope, gate, portable-enforcement, or product byte. Only `R`
is integration-eligible, and evidence always names the revision where it ran.

The M1 gate generation is a different transaction against a different plan, and
the difference is not cosmetic. M1 is `Closed`, so it uses
`amendment-transaction-v2`: one atomic proposal `A` carrying the amended gate,
its appended generation row, and both rebound artifacts together, and a child
`R` that completes only that row's authority and evidence. It never shares a
revision with an M2 plan amendment.

No M2 product implementation merges while M2 is red or before closure. No
rollback claim extends to a data root written by a different source revision.

<a id="technical-plan-packaging"></a>
### Packaging

Concept: [Milestone scope](M2.md#concept-plan-scope).

No package is published or installed, and no version is tagged. ADR 0001's
umbrella direction and ADR 0002's runtime floor are unchanged.

The planned inventory becomes exactly seven applications with exact roles:
`loopex_protocol` as `:contract`, `loopex` as `:core`, `loopex_store_local`,
`loopex_llm_reqllm`, and `loopex_executor_local` as `:edge`, and
`loopex_reference_client` and `loopex_cli` as `:client`. The role rules are:

- `:contract` declares no dependency of any kind, in any environment;
- `:core` declares exactly one production dependency, `:loopex_protocol`, and no
  external, edge, or client dependency in any environment;
- `:edge` declares a production dependency on `:loopex`, may also depend on
  `:loopex_protocol`, and imports no concrete sibling adapter;
- `:client` declares a production dependency on `:loopex`, may also depend on
  `:loopex_protocol`, may declare production dependencies on the `:edge`
  applications it composes, may declare no external dependency, and may not
  depend on another `:client`.

Neither new port adds an application. The `Loopex.Policy` and `ArtifactStore`
behaviours are declared in core, their reusable conformance suites live with the
applications that implement them, and the local artifact-store adapter lives in
`loopex_store_local`.

`Loopex.Policy.AllowAll` ships in `loopex_reference_client`, the `:client`
application that is Loopex's reference host, where ADR 0009 places it. Hosts own
policy, and deciding to trust one's own workspace is exactly such a decision. No
edge ships a permissive policy: an edge that did would answer the host's question
on behalf of every embedder who composes that executor — including the embedders
who compose it precisely because they intend to police it — and the permissive
module would then be inherited by the first isolated or remote hand that reuses
the edge's composition. An edge supplies a mechanism; it does not get to answer
the host's question.

Nothing depends on a `:client` to reach a policy.
`apps/loopex_executor_local/test/host_policy_test.exs` owns the deny, fail-closed,
and refusal-to-start selectors and defines its own policy fixtures inside the
test file — one refusing, one permitting, and the raising, sleeping, and
malformed-return modules the fail-closed cases need. It imports nothing from any
client. That split is also the correct division of what each selector proves: the
edge proves the runtime property that a permissive policy applies only when named
and that omitting the option refuses start, which needs a fixture rather than a
shipped module; the reference client's own lane proves that its shipped
`AllowAll` allows everything and emits one notice, which is a property of that
module and belongs where the module lives.

The consequence for the operator command is stated rather than worked around. A
`:client` may not depend on another `:client`, so `loopex_cli` cannot use the
reference client's `AllowAll` and ships its own named permissive policy for a
trusted local developer, selected only through an explicit `--policy` value and
emitting the same single permissive-authority notice. Two reference hosts each
naming their own policy is the ownership ADR 0009 describes.

This changes the repository's own dependency check. `mix loopex.deps_budget` and
its source, `apps/loopex/lib/mix/tasks/loopex.deps_budget.ex`, are product code
this milestone edits: the planned inventory grows from six named applications to
seven and the client rule widens as above. Its adversarial corpus in
`apps/loopex/test/deps_budget_test.exs` grows two cases for the new inventory and
the new client rule, raising its locked minimum from M1's 25 to 27. Both files
are bound by the closed M1 gate, which is why the amendment in Prerequisites is
a prerequisite rather than a note. The M2 gate does not bind either file's
bytes, because binding bytes the milestone must change would lock a digest
acceptance already knows is wrong; it locks the command and both corpus
identities instead. The M0 gate locks the command without binding its bytes and
must still pass.

`loopex_llm_reqllm` remains the only application permitted a direct external
dependency, exactly `{:req_llm, "~> 1.17.1"}` without source options. Core
remains Elixir/Erlang standard-library and OTP only. `loopex_cli` declares
production dependencies on `:loopex`, `:loopex_store_local`,
`:loopex_llm_reqllm`, and `:loopex_executor_local`, and no external dependency
in any environment; its argument parsing, signal handling, and terminal output
are standard library and OTP only.

The operator entrypoint is an `escript`. `apps/loopex_cli/mix.exs` declares an
`escript` main module, `mix escript.build` produces an executable named `loopex`
in that application, and `loopex --version` reports the single version train's
value. The escript must build and run on all three locked lanes. Because an
escript starts with no application tree, the shipped composition is responsible
for starting one — `:ssl`, the HTTP client stack `req_llm` pulls in, telemetry,
and the Loopex applications — and that work counts against the composition
ceiling below. The escript is not installed, signed, archived, attached to a
release, or published, and the gate produces it inside its own owned task root.

The root `VERSION` file stays `0.0.0`. Every application reads that file at
compile time, and `mix loopex.version_train` continues to prove the single
train. Keeping it is not only a scope decision: the bound
`scripts/m1-exunit-runner.exs` refuses any sealed real-path report whose adapter
build is not `loopex_llm_reqllm@0.0.0` or whose executor build is not
`loopex_executor_local@0.0.0`, so a version bump would make every real-provider
role in this gate unsatisfiable without amending another immutable artifact.

<a id="technical-plan-minimalism"></a>
### Proportional Minimalism Budget

Concept: [Milestone scope](M2.md#concept-plan-scope).

The operator experience is the unit of value. Focused tests, retained evidence,
and repository checks support it and cannot satisfy an outcome in its place.

**Five boundary behaviours, each justified by the concrete implementations that
exist when the milestone ships.** The count is not the argument; the
implementations are.

| Port | Concrete implementations at ship | Why direct code is insufficient |
| --- | --- | --- |
| Store | In-memory and durable local | Accepted in M1; two implementations already share one conformance suite |
| Model | Deterministic and ReqLLM | Accepted in M1; Outcome 2's streaming suite is the second contract both must satisfy |
| Executor | Trusted-local | Accepted in M1 under ADR 0007; the isolated executor is the named second implementation the protocol exists for |
| Policy | The reference client's `AllowAll`, the command's own permissive policy, and the refusing policy the demonstration selects | ADR 0009 creates it and the founding vision requires it. Host authority cannot stay a literal term inside core, because the decision belongs to the host and must be able to fail closed |
| ArtifactStore | Local filesystem adapter | The vision assigns oversized tool output here. `bash` running a real test suite produces it on the first genuine task, and a bounded model-facing result that discards the remainder is a defect rather than a bound |

A sixth boundary behaviour, or a generic layer above these five, requires an
accepted plan amendment naming the concrete current implementations it unifies
and why direct code is insufficient. The tool registry is not one: it is
runtime-scoped data plus resolution rules inside core, defines no replaceable
implementation, and adds no behaviour module. That is also why it is a
constraint rather than an outcome — an internal mechanism promoted to a feature
row invites the milestone to spend on the mechanism instead of on what an
operator can do with it.

**The registry unifies six concrete tool implementations, all of which exist in
this repository when it ships:** `read`, `write`, `edit`, and `bash`, plus M1's
two demonstration tools `loopex.demo.write` and `loopex.demo.wait_write`. The
demonstration tools are retained as registered generations that no active tool
profile offers, because M1's inherited protected executor and recovery selectors
exercise them and the registry must prove it resolves definitions outside the
active profile. Four of the six are new in this milestone. Retaining the other
two costs two definition records and no prompt tokens; deleting them would break
inherited protection to save nothing.

**The command surface is a client application, not a boundary.** It defines no
behaviour, no callback, and no replaceable implementation. It is permitted
exactly one composition module that names concrete adapters, and that module has
a hard ceiling: at most eighty effective lines, counting neither blank lines nor
comments, measured by a protected test. That ceiling is the executable form of
the vision's requirement that one page of code can start a runtime, create a
session, submit a prompt, and consume events — a budget the repository currently
fails, because the only such composition is test support. Eighty rather than
sixty, because the same module must also start the OTP application tree an
escript does not start for it and must name five concrete implementations rather
than three; a ceiling low enough to force compression buys a smaller number by
hiding work, which is the opposite of what the budget is for.

**The reference prompt has one measured ceiling.** The base system prompt plus
the active built-in tool definitions must measure under one thousand tokens
before project context. The measurement is deterministic and dependency-free: a
documented conservative estimator over the exact UTF-8 bytes, with a recorded
estimator identity and version, asserted by a protected credential-free test,
and reported whether it passes or fails. A measurement that needs a tokenizer
dependency is out of budget. The attended real-provider demonstration record
additionally reports the provider's own input-token count for the same prompt,
which review compares against the estimator; it is not a second gate-enforced
ceiling, because the bound `scripts/m1-exunit-runner.exs` seals a fixed
real-path field set and cannot carry an additional field without amending an
immutable artifact.

**Explicitly forbidden in this milestone,** whether or not something would find
them convenient: a transport behaviour, a daemon, a socket, a wire protocol or
line framing, a controller lease, a broker, a policy engine, a generic event
bus, a plugin macro system, a context-provider or transformer registry, an
alternate session engine, a second composition module, a terminal
user-interface framework, and any built-in sub-agent, plan, objective,
background job, team workflow, or social channel. The last group is a standing
vision constraint, not an M2 preference.

**Gate machinery is limited to two files:** the new `scripts/check-m2-gate.sh`
and the reused, already-proved `scripts/m1-exunit-runner.exs`. M2 adds no
separate evidence verifier program, no environment launcher, and no generalized
evidence framework. The retained-evidence validation M2 does perform lives
inside that one runner, and the gate document enumerates exactly which checks it
runs and which judgments remain review's, so no reader infers enforcement that
does not exist. Where M2 needs a check M1 already proved, it invokes M1's
machinery instead of writing a second one.

The opening behavioural probe lives inside that same runner rather than becoming
a third gate file. It is one Elixir program the runner writes into its own
isolated evidence root, and it is deliberately not test support, not a fixture,
and not a reusable harness: it exists to make the declared red an observation of
the loop rather than a statement about files. Its model adapter is a probe-local
observer, and nothing it produces is evidence for any outcome or for the attended
demonstration.

Raw line count is recorded at closure as a review signal, never a pass
threshold, except for the two scope-specific ceilings above, which the gate
locks. Required clarity, failure handling, and evidence are not traded for
compression.
<!-- loopex:plan-technical-envelope:end -->
