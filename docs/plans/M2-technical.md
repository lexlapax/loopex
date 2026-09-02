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
  Every new Core Runtime or session-journal fact this milestone commits — a
  conversation turn, a tool definition generation, an artifact descriptor, a
  denial, a steer, or a cancellation — enters through one catalogued production
  transition. Kind-specific edge durability remains separate exactly where the
  vision and accepted decisions assign it: ADR 0015's ArtifactStore owns object
  and immutable-use bytes, and ADR 0016's Local executor ledger owns effect
  admission, pre-effect refusal, open authority, and receipt truth. Neither is
  alternate session truth or dispatch authority for Core. The session journal
  advances only after the relevant bounded edge fact is validated, and edge
  unavailability fails closed rather than being rewritten as a Store fact.
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

Seven successor decisions were accepted during implementation and are closure
prerequisites under Amendment 4. Each replaces only the clauses it names; every
remaining clause of the earlier accepted decisions stays unchanged:

- **ADR 0012 — Executor cancellation capability.** `cancel/2` is a required,
  job-scoped executor callback. Missing, malformed, raised, exited, timed-out,
  `{:ok, :unconfirmed}`, and `{:error, reason}` answers all prove only
  unconfirmed cleanup. Outcomes 4 and 8 depend on that fail-closed boundary.
- **ADR 0013 — Run deadline commitment at first request staging.** Prompt
  admission and follow-up promotion commit the declared duration; the first
  staged model request fixes the absolute instant once for that run. Outcomes 1
  and 3 depend on that deterministic split.
- **ADR 0014 — Stream closure at owner loss.** Closure remains the last item
  while its process-local owner can state it truthfully, but abrupt owner death
  and recognized executor owner loss without a retained terminal fact end the
  transient plane without inventing a closure. Outcomes 1, 2, and 10 depend on
  that producer-liveness boundary and on the consumer's durable fallback.
- **ADR 0015 — Artifact object and use identity.** Content identity and the
  immutable reason one call retained those bytes are separate. Outcome 5's
  compact public reference names both identities while exact opaque provenance
  stays privately resolvable and integrity checked. Outcomes 5 and 10 depend on
  its Core-validated object-locator retrieval path.
- **ADR 0016 — Configured cancellation observation.** One durable session value
  derives executor observation, receipt retention, terminal rendering, and the
  command backstop. Outcomes 4, 8, 9, and 10 depend on every production observer
  honoring the period the operator selected.
- **ADR 0017 — Durable context and record admission budgets.** One committed
  estimator-owned context ceiling and the Store's exact item ceiling both bind
  before dispatch. Outcomes 1, 3, 7, 10, and 11 depend on exact refusal receipts,
  content-bearing input preflight, deterministic recovery, the composition's
  resolved default, and independent provider-context and durable-record admission.
- **ADR 0018 — Provider attempt authority and recovery.** Durable staged bytes
  identify one intended model operation but never authorize redispatch. Control
  linearizes one provider dispatch by sending a one-use permit for the exact
  attempt identity; version 1 permits attempt two only after attempt one commits
  exact pretransport `not_dispatched` proof. A recovered unresolved attempt is
  `dispatched_or_unknown`, is conservatively charged, and is never redispatched;
  incomplete provider usage consumes the exact remaining cumulative allowance
  rather than inventing a partial cost. Outcomes 1 and 2 depend on that cost,
  recovery, and stream-domain boundary.

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

**Three decisions are disposed by accepting this plan pair itself,** in the way
ADR 0008 was disposed by accepting an existing plan's requirement for it.
None of the three is implicit; each is named so acceptance is a decision rather
than a side effect.

**One. An eighth application, a new `:composition` role, and the client rule
that admits it.** Two applications are added: `apps/loopex_cli` with role
`:client`, and `apps/loopex_composition` with the new role `:composition`. The
planned inventory therefore becomes eight applications, and `:composition` is
added to the existing role set, which already carries `:extension` for ADR
0003's protocol-only contributor, so the set becomes `:contract`, `:core`,
`:edge`, `:composition`, `:client`, and `:extension`. `:extension` is untouched
by this milestone and must survive the edit.

The composition is wiring and nothing else. It names the concrete Store, Model,
Executor, and ArtifactStore implementations, starts the OTP application tree an
`escript` does not start for it, starts a runtime, and returns it. It ships no
policy and refuses to start unless the host supplies the one that governs the
run. The `loopex` command depends on it, and an independent fixture composes
through it without depending on the command, so an embedder on those same
reference adapters can depend on the shipped wiring rather than copy it. That is
the whole point of shipping it: a snippet each such embedder copies is
re-derived once per embedder and goes stale silently the first time the kernel's
start-up shape changes, while a shipped application changes once and breaks the
build of every dependant that must change with it. It is that reference stack
and no more: an embedder choosing a different Store,
Model, Executor, or ArtifactStore composes the public ports and the `Loopex`
facade itself, and M2 ships no generic wiring layer for that case.

**Why a new role rather than a wider `:client`.** A composition names concrete
adapters by definition, which is exactly what an `:edge` may not do, and it must
be depended on, which is exactly what a `:client` may not be; it fits neither
existing role, so the choice is between inventing a role and weakening one of
the two rules that keep the umbrella's direction legible. Widening `:client` to
permit one client-to-client dependency was the alternative and is rejected on
three counts: an acceptance review deliberately kept that rule narrow, the
widening would apply to every client forever rather than to the one case that
needs it, and it would let the command reach the reference client's `AllowAll`,
which is the precise inheritance decision three exists to prevent. Two further
placements were considered and rejected for the same reason each rule exists.
Putting the composition in an `:edge` would let an adapter import a concrete
sibling, and the composition would then be inherited by the first isolated or
remote hand that reuses that edge — the same argument that keeps a permissive
policy out of an edge. Putting it in `:core` would invert the founding
dependency direction, because core may name no concrete implementation at all.

The new rules are exact. A `:composition` declares a production dependency on
`:loopex`, may also depend on `:loopex_protocol`, declares production
dependencies on the in-umbrella `:edge` applications it composes, may declare no
external dependency in any environment, and may depend on no `:client` and on no
other `:composition`. A `:client` declares a production dependency on `:loopex`,
may declare a production dependency on at most one `:composition`, may declare in-umbrella `:edge` dependencies only in
tests exactly as M1 already permitted, may declare no external dependency, and
may not depend on another `:client`. Nothing depends on a `:client`.

Taken together this is narrower in production than the widened client rule it
replaces, not wider: no client gains a production edge dependency, `:client` to
`:client` stays forbidden, dependency direction is unchanged because every new
edge is still inward, and exactly one application — the single `:composition` —
is permitted to declare a production dependency on the concrete `:edge`
applications, test-only client dependencies excepted as above. That dependency
statement is the enforceable form of the rule and is what `mix loopex.deps_budget`
checks; it is not a claim that the repository is source-inspected for concrete
module references. The composition's own contents are bounded by the
`:composition` role rule, by the Ownership rules below, and by the measured
one-hundred-eighty-effective-line module ceiling in Minimalism below.

**Two. Two narrow ports join the three M1 boundary behaviours.** `Loopex.Policy`
is created by ADR 0009 and required by the founding vision's host policy port;
it replaces the literal `{:host_policy, :allow}` term with one `decide/1`, named to the runtime through the `:policy` start option
callback whose return is `{:allow, context}`, `{:deny, category}`, or
`{:defer, request}`. There is one callback rather than one per decision class,
and `{:defer, _}` is the clause M2 declares and refuses rather than implements.
An `ArtifactStore` port owns oversized tool output, which the vision assigns to
it and which M2 must produce the moment `bash` runs a real test suite. Each ships
with exactly one local adapter and one reusable conformance suite, inside an
existing application. No third new port, and no generic layer above the five, is
authorized by this acceptance.

**Three. Two shipped permissive policies rather than one.** A `:client` may not
depend on another `:client`, so `apps/loopex_cli` cannot reach the reference
client's `AllowAll` and names its own. The composition cannot supply one for
either of them: it owns wiring, never authority, and a permissive default
shipped there would answer the host's question once for every embedder that
depends on it. Both are permission-granting modules an operator selects
explicitly, both print the same single notice, neither is ever an implicit
fallback, and both carry a locked case. Widening the client rule to permit a
client-to-client dependency was the alternative and would undercut decision
one.

**The first prerequisite this plan pair names but cannot dispose: the recorded
disposition of the `bound_reached` vision change.** M2 and ADR 0010 both depend
on a run being able to end at a declared bound without that ending being a
failure. That member was added to the vision's closed run terminal algebra by an
explicit maintainer decision, and the algebra is a founding boundary. Accepting
ADR 0010, or this plan pair, does not dispose it and must not be read as doing
so: a founding boundary change carries its own record, naming the principle, the
evidence, the compatibility impact, and the migration path — which is empty here,
because nothing is released and no session record exists. If that disposition is
not recorded, ADR 0010 and Outcome 1 rest on an algebra member no authority
accepted, and the honest correction is to record it, not to reinterpret the
outcome. Its shape is fixed here for the same reason the second prerequisite's
is:

- **Decision owner.** The maintainer. A change to a founding boundary is
  explicitly non-delegable, and accepting ADR 0010 or this plan pair neither
  implies it, authorizes it, nor schedules it.
- **Durable disposition anchor.** Recorded 2026-08-23 as
  [`disposition-bound-reached-vision-change-2026-08-23`](../developer/agent-context-map.md#disposition-bound-reached-vision-change-2026-08-23),
  in the durable register every earlier authority disposition in this repository
  already uses. That anchor names the principle changed, the evidence, the
  compatibility impact, and the empty migration path, and it is the single
  pointer this plan pair and ADR 0010 both read. The prerequisite is met by that
  record alone: no plan text, ADR text, or gate result supplies it, and were it
  absent none of them could.

**The second prerequisite this plan pair named but could not dispose was M1 gate
generation 7.** M1's closed gate bound nine paths by SHA-256, and M2 had to
change two of them:

| Bound path | Why M2 must change it |
| --- | --- |
| `apps/loopex/lib/mix/tasks/loopex.deps_budget.ex` | Its planned-inventory constant freezes the repository at exactly six applications with the reference client as the only `:client`, and its role set contains no `:composition` at all. An eighth application fails it, and so do the new role and the client rule that admits one composition |
| `apps/loopex/test/deps_budget_test.exs` | Its adversarial corpus asserts the M1 inventory and the M1 client rule, and must gain the three cases that prove the M2 eight-application inventory, the `:composition` role's own rule, and the client rule that admits at most one composition |

These two artifacts are where the eighth application and the new role are
proved. M2 binds no third artifact for the inventory and role change, which is
why the generation below rebinds exactly these two and no others.

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
  pair does not imply it, authorize it, or schedule it. It was approved
  separately on 2026-08-23 and recorded as
  `disposition-m1-gate-generation-exception-2026-08-23` in
  [the context map](../developer/agent-context-map.md#disposition-m1-gate-generation-exception-2026-08-23),
  scoped to exactly the two artifacts below. That approval authorizes the
  transaction; it does not approve any particular proposal `A`, which still
  requires its own exact-SHA review and the `A` to `R` transition review.
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
  document, that gate's next consecutively numbered amendment section, the
  `<a id="amendment-transaction-v2"></a>` marker the amended gate acquired in
  that first additive generation, its new
  generation row with an empty authority, evidence, and candidate, and both
  rebound artifacts together. Splitting the artifact change from the generation
  row across two revisions permanently invalidates history and is not a
  recoverable mistake. The row carries its gate digest at `A` but not its
  candidate, because a commit cannot name its own hash. After exact-SHA review
  and explicit acceptance, the immediate child `R` completes that row's
  authority, evidence, and the candidate it binds, which is exact `A`; the
  evidence is one new amendment-specific anchor in `docs/developer/agent-context-map.md`,
  the register every earlier authority disposition uses, written as a local link
  carrying its fragment, that did not exist at `A`. An `R` that leaves the
  candidate empty is refused by binding validation, and by the rule above that
  is not recoverable either. Only `R` is integration-eligible.
- **The declared truthful reproof.** M1 gate generation 8 removed the
  working-tree freeze from retained historical evidence while preserving every
  candidate-side digest check, so the complete M1 gate can now judge a later
  product revision. Before M2 closes, `/bin/bash -p scripts/check-m1-gate.sh`
  must be GREEN at the exact M2 evidence candidate and that retained row must
  bind the M1 gate generation and seed that ran. M2's inherited selector roles
  remain an independent behavioural reproof; they neither replace nor are
  replaced by the complete closed-gate run.
- **The alternative, and why this plan does not recommend it.** The enforcement
  could instead be changed so the status check exempts a `Closed` milestone's
  bound artifacts. That is one edit instead of a transaction, and it is worse:
  it silently retires digest protection for every closed gate, forever, to avoid
  one named exception. It is also portable-enforcement weakening and therefore
  equally non-delegable. The generation keeps the protection, keeps every
  earlier generation governing the revisions it covered, and pays only for the
  change it needs.

Generation 7's accepted `R` closed the M0, bootstrap, and status red caused by
those two files. Generation 8 later restored the complete M1 gate's ability to
judge later product revisions. Neither generation added scope, changed an M1
outcome, or reopened its lifecycle state.

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
absolute deadline instant bounds every operation the run owns rather than only
the gaps between turns. It is propagated into the supervised model call, and it
is carried on every executor job the run dispatches, where the effective job
deadline is the minimum of that instant and the wall-time budget the tool
declares and expiry enters ADR 0009's cancellation sequence. There is no
independent per-call, per-transport, or per-tool timeout that can outlast it, so
no two enforcement points can disagree about when the run ends. A tool call whose
run deadline has already passed when its intent would commit is not dispatched at
all, mints no grant, and takes a terminal fact anyway. The completion race is
decided by committed journal order: a
reply that commits before the abort is admitted completes that turn and its
assistant message is canonical history, while an abort admitted first commits no
assistant message and keeps the late reply as attempt evidence only. A complete
valid provider usage pair is charged exactly as reported even when the reply
itself is unreadable or too large for canonical conversation. Any possibly
dispatched attempt whose usage pair is absent, partial, malformed, or outside
the unsigned-64 domain consumes the entire remaining cumulative token budget and
is marked `estimated` before any later provider dispatch. The charge is a
fail-safe allowance for externally billed uncertainty, not a reconstructed
provider invoice. Reaching a bound commits `bound_reached`, the
terminal outcome the vision added for exactly this ending, carrying the vision's
exact `bound_reached(bound, observed)` payload and no more; the declared limit
and the accounting source are sibling fields of the same terminal record,
recorded beside the outcome rather than inside it, because the closed terminal
algebra is a released shape this milestone may use but may not widen. It is
never recorded as a failure: nothing malfunctioned, the committed conversation is complete, and a later run
continues it under a new bound. A reached deadline is the one bound whose commit
waits: `bound_reached(:deadline)` commits only once every owned operation has
reached a validated terminal fact and every captured executor process group
associated with those operations has been confirmed quiescent, and one
unprovable effect or unconfirmed cleanup finishes the run
`outcome_unknown` with that reconciliation reference instead.

**Two digests, two names.** `M2` renames the canonical model request's digest
field to `staged_request_digest`. Today the model request carries
`canonical_request_digest`, the executor job's name, and one identifier holding
two opposite retry rules is what let the executor rule be carried onto a model
call more than once during this plan's own review. The staged digest identifies
one intended model operation and is never retry authority by itself. That
operation durably opens attempt one before Control directly sends one
exact-identity one-use permit to the blocked worker. Version 1 permits exactly
one attempt two, and only after attempt one has durably settled with exact
pretransport `not_dispatched` proof; attempt two reuses the admitted staged bytes
and digest under its distinct attempt identity. Any possibly dispatched
unsettled or error attempt without complete valid reported usage is
conservatively charged and terminal and opens no successor attempt; a complete
valid pair is retained and charged exactly. An executor attempt still carries its own attempt-bound
`canonical_request_digest` because the job canonicalization covers attempt
identity; no provider rule applies to it. The gate's opening probe observes
either digest name, exactly as it already asks for the `M2` shape and falls back
to the `M1` shape, because it runs against the tree it is judging. The fallback
covers the `:policy` option as well as the tool set, since an `M2` runtime refuses
to start without one and would otherwise refuse the probe.

**The deadline duration becomes an instant at first staging.** Prompt admission
and follow-up promotion commit only the declared duration. The first model
request staged for either kind of run fixes one absolute instant, stores it
put-once, and every later turn, retry, or recovering owner reuses it unchanged.
Downtime before that first staging is therefore not charged; downtime after it
is. This is ADR 0013's deterministic boundary and no admission, promotion, or
terminal record samples a fresh clock to rebuild an already named transaction.

**Context admission and Store admission are independent.** Every new run commits
one positive unsigned-64-bit `context_token_budget` outside `:bounds`; the
reference CLI and composition use 8,192 only when a new prompt omits it, while a
direct runtime host must choose. Promotion and recovery inherit the committed
value and never consult a current default. `loopex.context_bytes.v1` measures
only the exact final provider-visible messages and model-facing tool projections
as deterministic repository policy; it is neither provider capacity nor billing
truth. Separately, every exact durable candidate is normalized and measured
against the Store's fixed 65,536-byte item ceiling before a transaction or any
authority it could enable. Staged request sizing uses the final
`model_request_committed` fixed point. Prompt, steer, and follow-up admission
preflight every deterministic durable record, public event, and future terminal
they make reachable. An optional project class that alone overflows either
request dimension is withheld whole with a compact receipt; required context or
record overflow makes no provider call and commits the exact non-retryable
context failure. Neither is `bound_reached`.

**One cleanup value governs every production observer.** `session_genesis_v2`
commits the operator-selected positive unsigned-64-bit period. Core derives
ADR 0016's executor-observation, receipt-retention, execute-result, terminal,
cache, and command-backstop intervals with checked arithmetic and no hidden cap;
each multi-phase cleanup, retention, or observation operation derives one
monotonic deadline from its own interval and every phase spends only that
operation's remainder rather than refreshing it. Prepared recovery transfers one opaque activation capability before
ordinary work may resume, so `resume` and `cancel` compare explicit configuration
and settle activation or abort without a race. Legacy entry arities remain only
defensive compatibility paths; the reference stack uses the configured paths.

**Local effect authority is one durable root.** Before a tool effect, Local
preflights the complete genesis and effect-intent records, samples wall and
monotonic time as one pair, derives one private non-extendable action deadline,
and requires both that fence and the immutable wall deadline at every
effect-authorizing transition. Under one root-wide claim it installs the
digest-bound admission marker and open authority immediately before a single
worker permit. Every Local instance sharing that prepared root observes the same
generation, open, refusal, and receipt truth; unresolved open authority or a
malformed or unavailable claim quarantines new effects rather than allowing a
duplicate. The worker and command cleanup are owned by launch guards, not
sampled numeric identifiers. A terminal receipt records cleanup confirmation and
the committed retention bound, and mandatory receipt shape is reserved before
the effect; if complete output cannot fit inline, ADR 0015 artifact retention may
make it fit, but failure never claims an unrepresented suffix is reconstructible.

**Two kinds of sequence domain, and a label on every item.** Following ADR 0011,
`model_sequence` is per model attempt and `progress_sequence` is per
`(operation_id, attempt)`. Every item carries the `stream_domain_id` derived from
the committed
`("loopex.stream_domain.v1", domain_kind, session_id, operation_id, attempt)`
identity, never from an adapter or executor event. The length-aware canonical
encoding is injective for arbitrary binary members; its truncated SHA-256 label
is collision-resistant, stable, and sampled for distinctness. A retry opens a
new domain, so several domains under one turn are ordinary.

While the coordinator remains authoritative, one relay is the sole emitter and
orderer. The relay assigns `model_sequence`. An executor supplies
`progress_sequence`; the coordinator validates the next expected value and the
relay carries that value unchanged. A wrong identity or sequence advances
nothing. A valid identity and expected sequence with a refused bounded payload
consumes the executor's sequence but not its byte offset, so the next projected
item exposes the visible gap rather than renumbering history. Every progress
item and closure carries the coordinator's `base_event_sequence` captured from
the current durable event sequence when that model attempt or executor job was
dispatched.

A complete model or tool domain closes with the producer's retained
`delta_count` or `progress_count`; an abandoned domain closes with the relay's
projected count. The closing item, its total, and refused-progress accounting
are non-durable, and a refusal diagnostic is transient-only. Nothing after
closure is emitted.

ADR 0014 narrows only that universal producer-liveness promise. Abrupt owner
death ends the relay ahead of its queued backlog without a closure. Recognized
executor owner loss without a retained terminal operation fact fences progress,
ends the stale relay without a closure, leaves the effectful worker alive for
reconciliation, and never calls the effect abandoned. A retained terminal model
reply or executor receipt may still close its originating domain `complete`
after handoff because the durable fact fixes the disposition and producer count.
A delivered live-model supersession notification terminates and drains the
effect-free worker before closing its old domain `abandoned`. The successor
never reuses or closes a predecessor's domain.

The Control owner slot serializes the current-owner decision with relay emission
or ordinary closure. An unavailable Control is runtime unavailability, not an
owner-loss verdict. Closure remains an emission obligation rather than a
delivery guarantee: a consumer missing one falls back to the durable record and
never infers abandonment or starts a timeout to decide.

ADR 0011's progress parameter remains on `execute/5`; ADR 0012 adds the required
job-scoped `cancel/2` operation. Only `{:ok, :cleaned}` confirms cleanup;
`{:ok, :unconfirmed}`, `{:error, reason}`, missing or malformed callbacks,
raises, exits, and defensive timeout all remain unconfirmed. Executor progress
carries the full identity, epoch, digest, and fence tuple, and the coordinator
validates every binding fail-closed before projecting a narrower client item. A
refused event is dropped and counted privately; it is never projected,
journaled, published, or allowed to affect an outcome.

**Stopping is reported, not promised.** A run finishes `cancelled` only where
every owned operation reached a validated terminal fact and every captured
executor process group associated with those operations was confirmed
quiescent. Anything less finishes `outcome_unknown` carrying the reconciliation
reference of the operation that could not be proved. A reached
deadline is bounded in exactly the same way and carries the same precedence, so
no document, help text, or transcript this milestone ships says that an interrupt
or an expired deadline always ends a run cleanly.

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

**A spilled artifact has object truth and use truth.** The Core-owned
`ArtifactStore` facade admits exactly media type, role, session, run, operation,
attempt, and tool-call provenance; the five private values never enter the
compact reference. Identical bytes converge on one immutable object triple, while
each retention publishes one immutable canonicalization-versioned use whose
digest binds that object triple and the exact private provenance. The eight-key
reference carries both digests and only the digest-derived use locator. Core
verifies object identity against input bytes, resolves the use immediately, and
refuses any substitution, missing sidecar, unknown version, allocation-bound
failure, or integrity mismatch before success. The local adapter publishes the
object then the use durably and convergently; M2 performs no collection. Outcome
5's retrieval is a real command — `loopex artifact <reference>` — projecting the
same facade an embedder calls. It reads by opaque object locator and never
constructs fake use metadata or reaches the adapter's storage layout; an
authorized host resolves provenance only through `describe/2`. Operator guidance
states plainly that the local adapter stores artifact bytes and session records
unencrypted under the resolved state root.

**Each reference host names its own permissive policy.** ADR 0009 places
`Loopex.Policy.AllowAll` in `loopex_reference_client`, and a `:client` may not
depend on another `:client`, so `loopex_cli` cannot reach that module and does
not try to. It ships its own named permissive policy for a trusted local
developer, selected only when the operator passes the corresponding `--policy`
value, and emitting the same single permissive-authority notice. Two reference
hosts each making their own decision is the ownership the ADR describes; one
host importing the other's would be the relocation of authority it forbids. The
shipped composition ships no permissive policy either: it
takes the host's policy as a required argument and starts nothing without one,
so depending on the wiring never means inheriting somebody else's answer.

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
sole serial writer of Core session truth. The tool registry is runtime-scoped
read-mostly data reached through the explicit runtime reference; it registers no
global name and stores no session state. The model adapter and policy
implementation return evidence and publish no durable fact. ADR 0015's artifact
adapter does own immutable object and use durability, and ADR 0016's Local
executor owns its root generation, effect admission, pre-effect refusal, open
authority, and receipt ledger; those are kind-specific edge truths, never
alternate session journals or Core dispatch authority. Core advances session
truth only after it validates the relevant bounded edge fact. Conversation
history is a projection of committed session records, never a second store: a
turn is not part of the conversation until its record commits.

**Deltas are not truth.** A streamed text, reasoning, tool-call, or
tool-progress delta is projected transiently on the progress plane. Exactly one
reconstructed assistant message per turn becomes durable, and it becomes durable
before its stable public event. No delta is journaled, replayed, or promoted to
durable or stable public truth; a reconnecting or resuming caller sees the
committed message, never a partial one. A stream that ends without a complete
message commits nothing, and the turn fails truthfully.

**The command surface owns nothing durable, and the composition owns nothing
else.** `loopex_cli` calls only the public `Loopex` facade for every session
operation, including the interrupt path. M2 ships exactly one `:composition`
application, `apps/loopex_composition`, and only that role may declare a
production dependency on the concrete `:edge` applications; every other
production role reaches an adapter through a port. That dependency statement is
the rule, and `mix loopex.deps_budget` is what enforces it, over the declared
in-umbrella dependencies of each application rather than over arbitrary source.
Nothing in M2 claims a repository-wide source monopoly on naming a concrete
adapter, and no check in this gate looks for one. The composition's single module
uses that dependency only to build the runtime options passed to
`Loopex.start_link/1`; it takes the host's policy as a required argument,
supplies no default for it, and starts nothing when it is absent.
Test dependencies are unaffected: the inherited conformance, executor, and
reference-client selectors this gate re-runs at their exact M1 identities name
concrete adapters today and must keep doing so, which is why a client retains
its test-only edge dependencies. No module of `loopex_cli` may name a concrete Store,
Model, Executor, or ArtifactStore implementation, reference a coordinator,
journal, outbox, or cursor internal, hold a cursor as truth, or own a second
state machine. Beyond the public facade and the composition's entry function the
command names only the host policy modules an operator may select with
`--policy` — the host's own decision, and the one decision the composition
refuses to make for it. The gate proves that `loopex_cli` restriction by
inspecting the command application's own source, exactly as M1 proved it for the
reference client. That inspection is scoped to `loopex_cli` and to nothing else.

**Cancellation is same-process by construction.** The foreground command traps
the interrupt signal and calls the public abort operation on the session it is
running. It does not signal another process, write a control file, or open a
channel. `loopex cancel <session>` is a distinct, narrower operation: it applies
only where no live Runtime Control holds the session's placement key, acquires
ownership through a fresh resume command identity under the session's durable
`runtime_id`, and drives the session from durable evidence to `cancelled` or
`outcome_unknown`. Against a live owner it is refused by the command surface's
own placement exclusion over its state root, which is what ADR 0008 requires of a
host rather than something ADR 0008 enforces, with an explicit message, and that refusal is a locked case rather
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
   three declared bounds, ADR 0017 context and Store normalization, the delta
   algebra, the input queue, and the project-resource stage build on A. B also
   owns ADR 0018's versioned provider-attempt open and settlement reducers and
   Control's one-use permit operation. No tool implementation is integrated
   before B proves a turn dispatches only its committed and admitted bytes, and
   no model adapter is integrated before the deterministic adapter proves that
   staged identity alone cannot create a retry.

   B also owns both port arity changes, because no other workstream owns either
   and each touches every implementation at once. ADR 0011 makes `complete/2`
   into `complete/3`, which reaches three inherited M1 roles: 5a on
   `real_model_lane_test.exs`, and roles 5b and 5c on
   `real_model_session_test.exs`, of which only 5c runs the real case. Role 5b
   excludes it and is credential-free. The same decision makes `execute/4` into
   `execute/5`; its whole streaming change is one bounded in-VM progress
   function in the trailing position. ADR 0012 separately adds required,
   job-scoped `cancel/2`. Those changes reach inherited role 6 on
   `executor_test.exs` and both combined real-provider roles. None of those
   files is a bound artifact, so their bytes may change, but their locked case
   names and asserted behaviour are reproduced exactly at M1's identities and
   states. B carries the migration of the deterministic adapter, the ReqLLM
   adapter, the trusted-local executor, and every affected role in one rejoin
   rather than leaving it to whichever workstream trips over it, and it re-runs
   5b, 5c, and 6 before C begins, with 5c taking its credential through the
   gate's bounded frame. An implementation
   that emits no progress through either new parameter stays conformant, so the
   arity change is not a behaviour change for an adapter that does not stream.
3. **C — Coding tools, artifacts, and host policy rejoins third.**
   `loopex_executor_local` implements the four tools against A's contract, emits
   validated executor progress through B's new parameter, and gains ADR 0016's
   prepared root, root-wide admission ledger, dual-clock action fence, configured
   cleanup, receipt reservation, `deny` path, and launch-owned termination;
   `loopex_store_local` gains ADR 0015's object/use artifact adapter and immutable
   sidecars; and `loopex_reference_client` gains the shipped permissive policy
   and its own lane. The artifact object/use path rejoins before receipt fitting,
   and B's exact Store normalizer rejoins before either durable edge emits facts
   Core will admit. No edge imports a concrete sibling adapter, and no
   application depends on a `:client`.
4. **D — Cancellation and the session directory rejoins fourth.** Cancellation
   needs C's configured termination and ledger evidence and B's turn machine.
   Prepared owner activation, configuration-conflict abandonment, session
   status, and the exact interval formula land together so no recovered path can
   run under a current default. The session directory needs the resolved state
   root and ADR 0008 placement identity.
5. **E — Operator surface, composition, and demonstration rejoins last.**
   `loopex_composition` names the concrete adapters and starts the tree;
   `loopex_cli` builds only on the integrated A–D paths, through the public
   facade and that one composition entry point. Its first commit carries the
   eighth-application inventory and the `:composition` role rule, and the M1
   gate generation above lands with it. A private client loop, substitute store,
   fake provider, or bypass executor is not a demonstration of this milestone.

Core is a serial ownership chain across A, B, and D rather than parallel
writers, because those workstreams touch the same coordinator and session-state
modules. Parallel writing is confined to the pairs that own disjoint
applications. Every parallel writer uses non-overlapping file ownership,
separate branches or checkpoints, separate worktrees, and isolated build,
dependency, and state roots. No workstream creates an alternate durability
truth, authority path, or session loop to avoid a barrier. The ArtifactStore and
Local executor ledger are the two catalogued kind-specific durability domains
above, not exceptions a workstream may extend: neither owns conversation,
session terminal, command, queue, owner, or public-event truth, and every Core
consequence still enters through ADR 0006's owner-fenced Store transaction.

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

**Real-call attestations.** The same sealing is why the evidence that a real
call happened lives *beside* that report rather than inside it, in a record M2
owns and M2's gate validates. `docs/evidence/M2-real-call-attestations.md`
carries exactly three one-line JSON records, in the locked role order
`demonstration_db`, `inherited_5c`, `inherited_8b`, in this exact key order:

```json
{"role":"<role>","selector":"<safe tracked path>","provider":"<lowercase provider>","model":"<printable>","endpoint":"<printable>","adapter_build":"<printable>","calls":<positive integer>,"response_id_form":"<prefix>:<min>-<max>","provider_response_ids":"<id>+<id>...","input_tokens":<positive integer>,"output_tokens":<positive integer>,"candidate":"<40 lowercase hex>","recorded":"<RFC3339 UTC>"}
```

`provider_response_ids` names every provider response the role observed and
`calls` is their count; the token totals are the provider's own, across exactly
those responses.

`response_id_form` is the identifier form that provider documents, **declared by
the record rather than looked up in a list the gate carries.** It is written
`<prefix>:<min>-<max>`: a non-empty literal prefix of at most sixteen characters
drawn from `[A-Za-z0-9_-]`, then the inclusive length range of the remainder,
whose characters come from the same set, with `1 <= min <= max <= 128`.
Anthropic's documented form is written `msg_:16-64` and OpenAI's
chat-completions form `chatcmpl-:8-128`; neither appears anywhere in the runner.
All three records declare the same form, because all three already agree on the
provider the bound runner sealed, so no single record can relax the shape the
other two are held to. One record declares one form, which is what a role
running against one model at one endpoint produces; a role that observed two
identifier shapes could not be recorded, and no locked role is one.

The gate holds no opinion about which providers exist, and that is the point of
the change. The model boundary is replaceable by design, so a gate that
recognises two providers and fails closed on a third makes adding an adapter a
governance event rather than an adapter change. Validating a declared form is
weaker than validating a known one, and this plan says so rather than trading
the honesty for the strictness: a fabricator declares their own form, so the
declaration cannot make a fabricated identifier detectable. What the check keeps
is the internal consistency it was ever worth — every identifier has the shape
the record itself claims, no identifier is reused within or across records, and
the count and reported totals agree with each other — and what was always
load-bearing is untouched, because it was never the form. It is the auditor's
lookup of each identifier against the provider account.

Two locked cases give the record something to be about: a
deterministic case proving a real-provider evidence claim fails when the reply
carries no provider-supplied identifier, and a real case proving the shipped
adapter surfaces the provider's own identifier and reported usage where the
deterministic adapter reports nothing. Their exact identities and minima are the
gate's.

The limit is recorded here rather than left to be inferred. The runner proves
the record's shape and role order, that each record declares a well-formed
identifier form and that all three declare the same one, that every identifier
matches the form its own record declares and is reused neither within nor across
records, that the record's provider, model, endpoint, and adapter build are
byte-identical to the identity the bound runner sealed in the same run, and that `calls`, the identifier count, and the reported
totals are internally consistent and meet the floor each role's locked cases
imply. It proves nothing about whether a socket was opened, and it cannot bind a
retained identifier to a later run's calls. Confirming the identifiers and their
usage against the provider account is closure review's, and it is the only step
that reaches the provider. A record that satisfies the runner is a checkable
claim, not a proved one, and no document may describe it otherwise.

**Runner isolation.** The gate compiles into build roots it owns, not the
checkout's. `MIX_BUILD_PATH` takes precedence over `MIX_BUILD_ROOT`, so the
runner clears it wherever it sets a build root, refuses a probe or task root
that resolves inside the checkout or the operator's product state, and
fingerprints the checkout's own `_build` before and after the run so the
isolation is proved rather than declared. `apps/loopex/test/gate_isolation_test.exs`
is the locked corpus for that behaviour, so an ambient environment variable
cannot quietly return the runner to the checkout — which, left unfixed, can stop
the opening probe observing the loop at all and turn a real red into an
unavailable one.

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
| 1 | Generate legal multi-turn histories and prove the run continues while the model requests tools and ends when it does not; prove every request after the first contains the original prompt, the model's own prior assistant message including its tool call, and the real tool result rather than a synthesized string; prove the canonical request bytes and digest committed before each dispatch are exactly the bytes the adapter receives; prove a staged request carries complete canonical tool-definition bytes and its generation triple and is reconstructible and verifiable from the journal alone; prove every model-supplied tool-call argument is validated against the staged definition's declared schema before policy, grant, or job construction, and that a fractional JSON number survives canonical staging and durable dispatch without becoming an integer or a string; prove every turn after the first is canonical-history replay and that the reserved continuation field is present and empty; prove each of the maximum-turn, cumulative-token, and wall-clock bounds is evaluated before staging, commits `bound_reached` carrying the bound and the observed value and nothing else, with the declared limit and accounting source retained as sibling terminal-record fields, makes no further provider call, and fabricates no assistant message; prove prompt admission and follow-up promotion commit only the declared deadline duration, the first model request staging fixes one absolute instant put-once for that run, and every later turn, retry, or successor reuses it unchanged; prove the deadline also binds in-flight work, so a deadline reached mid-call aborts a request the provider may already have billed and only the pre-staging check is free; prove the committed instant bounds every operation the run owns, reaches the supervised model call rather than an independent per-call timeout, and is carried on every executor job so no adapter, transport, or tool bound can outlast it; prove a tool call whose run deadline already passed when its intent would commit is not dispatched, mints no grant, and still takes a terminal fact; prove `bound_reached(:deadline)` commits only after every owned operation has a validated terminal fact and every captured executor process group associated with those operations is confirmed quiescent, with an unprovable effect or cleanup finishing `outcome_unknown`; prove unknown effect truth outranks model completion, queued calls, and every run bound; prove the completion race is decided by committed journal order, so a reply committing first completes the turn and an abort admitted first commits no assistant message and retains the late reply as attempt evidence only; prove every raw model-reply candidate first satisfies the Store's plain-data, depth, item, and byte ceilings, then refuses any undeclared top-level key while projecting identity, usage, and tool-call maps to their declared provider-neutral nested fields before commit or late retention; prove the retained canonical reply preserves its bounded provider response identifier when present, carries paired and consistent streamed/count metadata, and excludes adapter-private fields and credentials; prove retained provider errors map to one generic bounded category; prove every staged model operation atomically commits its request and versioned attempt-one open before Control can authorize dispatch; prove the provider worker remains blocked until Control directly sends the exact one-use permit for that committed identity and no duplicate, wrong, stale, or post-succession permit can invoke the adapter; prove version 1 permits exactly two total attempts and that attempt two opens only after attempt one durably settles exact pretransport `not_dispatched`, reusing the admitted staged bytes and digest under a distinct attempt and stream domain; prove an unreadable or malformed live reply, task death, timeout, missing progress, ambiguous Control result, or recovered unresolved attempt settles `dispatched_or_unknown`, consumes the remaining cumulative-token allowance, permits no retry, and cannot be misreported as executor `outcome_unknown` or `bound_reached`; prove classification, bounded reply or error, accounting, conversation admission, next action, and terminal selection commit as one settlement verdict, so abort, deadline, owner loss, and a late reply cannot each choose a different winner; prove an abort or deadline retains a valid late canonical reply or bounded error as evidence bound to the exact provider attempt, never as canonical history, and checks the complete settlement record against the Store's exact item ceiling rather than sizing a reply alone; prove the coordinator waits for the task's own result or ordered `DOWN` rather than treating an earlier supervisor reply as proof that the mailbox is empty; prove prompt admission durably commits one context-token ceiling, promotion and recovery reuse it rather than a current default, the exact final provider-visible messages and tool projections are admitted under the named estimator while the exact final staged record is normalized and measured under the Store ceiling before dispatch, optional project content is withheld whole with a compact receipt when it alone exceeds either dimension, required context refuses with no provider call, and successful receipts record both observations and limits; prove complete valid provider usage is charged exactly, while missing, partial, malformed, or overflowing usage after possible dispatch consumes the exact remaining cumulative token allowance as estimated accounting and permits no later provider dispatch; prove every sampling bound is declared with no fallback; prove the committed instant is covered by a tool job's `canonical_request_digest` while dispatch-local `effective_job_deadline` is not; prove two attempts of one tool operation keep `operation_id` and use distinct attempt-bound job digests without inheriting any provider retry rule; prove a committed model attempt that expired while its owner was down is not redispatched and succession restores neither a spent permit nor retry allowance; prove every operation fact commits before the run ending derived from it and a Store refusal of that fact stops the owner rather than permitting an independent run ending; assert complete derived fault coverage over every new durable transition |
| 2 | Run one shared streaming conformance suite over every model adapter; prove each canonical delta kind carries exactly its declared bounded plain-data fields and no provider struct, pid, function, module atom, exception, terminal escape, credential, missing field, or unmeasured value; prove text is observable while its operation is incomplete and replaying emitted deltas reproduces the returned reply byte-identically; prove every item carries a coordinator-derived `stream_domain_id`, never one supplied by an adapter or executor event, and carries the current durable `base_event_sequence` captured when its own attempt or job dispatches; prove model and executor attempts use separate domains and retries open new domains rather than reusing or comparing predecessors; prove the relay assigns model sequences while an executor supplies progress sequences that the coordinator validates and carries unchanged, so a refused current-sequence payload consumes that producer sequence without consuming its byte offset and the next projected item exposes the visible gap; while an owner remains authoritative, prove one relay emits one content-free closure last and ends, with a complete model or tool closure carrying the retained producer `delta_count` or `progress_count` and an abandoned closure carrying the relay's projected count; prove no later item is emitted and no closure total or refusal accounting is durable; prove abrupt owner death ends the relay ahead of backlog with no closure; prove recognized executor owner loss without a retained terminal fact ends the stale plane without a false abandonment or worker termination, while a retained terminal fact may still close its originating domain `complete`; prove delivered live-model supersession terminates and drains the worker before an `abandoned` closure, and a prior fence cannot suppress that cleanup; prove a successor never reuses or closes the predecessor's domain and reconciles an effect before retry; prove Control serializes ownership admission with progress or ordinary closure, and unavailable Control reports runtime unavailability rather than owner loss; prove malformed counts and fields are refused rather than published or committed; prove the committed assistant message comes from the reply rather than deltas, a cancelled attempt commits no assistant message, and a late reply never becomes canonical; prove an adapter that emits nothing is conformant; prove the exported model reply contract declares the optional provider response identifier that durable attempt evidence preserves; prove a consumer missing closure falls back to the durable record without a timeout or inferred abandonment |
| 3 | Prove a prompt is admitted only while the session is settled and is refused with an explicit reason while a run is active; prove a steer names one active run, that a steer naming a different run or naming none while a run is active is rejected rather than retargeted, and that the runtime never infers which input class an input is; prove an admitted steer is applied after the current tool batch completes and before the next model request is staged, commits as a user-role conversation element in admission order, and does not attempt to reverse an effect already started; prove a steer is recorded applied only when a committed request actually carried it, so a steer admitted against a run that never staged another request is never reported as applied; prove a follow-up is queued and starts a new run only after the active run and its steering settle; prove a steer whose run reaches a terminal outcome first commits as unapplied with its reason rather than being discarded or promoted; prove at most one unapplied steer per run and at most one queued follow-up exist, and that both queue states are durable and survive owner succession; prove command replay is decided before current defaults and exact durable candidates are resolved; prove every new content-bearing prompt, steer, or follow-up preflights its exact command record, deterministic event, and reachable positive-bound terminal shapes against the Store ceiling, refusing an oversized command with one compact correlated result, no run or queue mutation, and no public event; prove a durably admitted abort resolves any unapplied steer and any queued follow-up as cancelled |
| 4 | Run one shared conformance suite over `read`, `write`, `edit`, and `bash`, covering bounded and truncation-reporting output, exact edit diagnostics, shell-versus-argv semantics, and filesystem-tool refusal of traversal, symlink, link-chain, sibling-prefix, non-ordinary-file, and static escape paths; prove containment is resolved immediately before the effect, writes and edits use create-exclusive staging plus rename, and disclose that resolution and effect are not one kernel operation, so a concurrently manipulated intermediate component can still race the check and `bash` is outside path containment because it takes a command; prove only a tool receiving a supplied command executes a controlled ADR 0007 OS process, whose first image and downstream command receive a constructed credential-free environment, while filesystem tools run bounded in the runtime and hold no environment; prove the captured process group is owned, its configured cleanup is one monotonic-clock period spanning cooperative grace, forced termination, confirmation, and a separately bounded receipt-retention share, no helper or group member survives a confirmed cleanup, and an unconfirmed or non-quiescent group remains unproven; prove the cleanup period is declared once at the session with a default, committed in versioned session truth, carried in every canonical job and receipt, used by a non-default active job rather than replaced by the executor startup default, and reported in every terminal, while the process-probe program remains executor configuration; prove the workspace lease and fencing token hold from dispatch through durable receipt, and loss during execution, artifact spill, quiescence, or receipt retention abandons the work and reports it unproven; prove only an answer carrying the declared pre-effect wrapper is a refusal before effect and every post-effect or undeclared error is unproven; prove each executor progress binding is validated against coordinator-held state, malformed or refused progress is never projected, and the private refusal count affects no outcome; prove the shipped local executor emits admitted `bash` child bytes before completion with the complete job identity, zero-based producer sequence, contiguous byte offset, bounded chunk, and receipt count exactly equal to callbacks, while filesystem and demonstration tools may emit no progress; prove every job carries the immutable wall-clock run deadline and derives a distinct monotonic action deadline from one paired wall/monotonic sample at Local handoff, so every effect-authorizing transition is fenced by both wall truth and the non-extendable monotonic bound, a backward wall jump cannot extend authority, and a forward jump expires by wall truth; prove the complete genesis and effect-intent records fit the Store before owner or executor authority is acquired; prove one prepared intact Local root binds generation, exact expanded path, directory identity, admission marker, open authority, refusal, and receipt under one root-wide first-writer claim, so two Local instances cannot both authorize one effect and unresolved open truth quarantines the root across restart; prove whole-root move or replacement and isolated generation copy are refused, while recording that partial copy or deletion, snapshot rollback, inode reuse, and administrator rewrite are outside the proof and require positive termination or host reboot before prior source starts against a fresh empty root; prove every effect worker is fenced by the Local instance and launch-owned guard that admitted it, never by a sampled numeric process identifier; prove the mandatory receipt envelope is reserved before effect, may shorten inline output or spill through ADR 0015 to fit, and reports bounded retention unavailable rather than claiming reconstruction when artifact retention fails; prove the tool definition's own ceiling is applied without mixing clock domains and the recorded effective wall deadline remains the one ADR 0009 validates; prove expiry and required configured cancellation share the same bounded cleanup path, only exact pre-effect refusal or confirmed cleanup of the captured process group can yield proved cleanup, and anything weaker yields `outcome_unknown` or bounded ledger unavailability with a reconciliation reference |
| 5 | Run one reusable `ArtifactStore` conformance suite over the local adapter, covering put, fetch, stat, describe, absent, integrity, repeated-object, and distinct-use cases; prove Core computes object digest and size from the exact input, admits only the closed five-label provenance shape, preserves all four opaque identifiers losslessly and the positive attempt privately, and refuses unknown or allocation-unsafe metadata before an adapter sees it; prove output beyond a tool's declared bound spills through the Core facade rather than truncating silently, supplying exact session, run, operation, attempt, and tool-call provenance from validated runtime and job identity; prove identical bytes share one immutable non-reassignable object triple while each retention preserves one canonicalization-versioned, content-digested immutable use record, and a successful compact eight-member reference names both identities without publishing that provenance; prove the use canonicalization enforces its scalar allocation guard and exact 131,072-byte ceiling, derives `use_locator` only as `"use:" <> use_digest`, and binds the complete object triple including its opaque locator; prove the local adapter publishes object then immutable use durably before success, concurrent identical publications converge, conflicts fail unavailable, and M2 collects neither a live object nor any referenced use sidecar; prove Core immediately resolves and verifies the adapter answer, so substituted digest/size/locator, wrong object from `stat/2`, wrong or missing use from `describe/2`, unknown version, corruption, and malformed reference all fail closed; prove the model-facing result stays under its bound and names what was truncated; prove the artifact round-trips byte-exactly and a corrupted or missing object or use is unavailable rather than empty content; prove the operator retrieves by the object locator carried in the compact reference through the public facade, resolved through the port rather than adapter storage layout, while an authorized caller resolves exact private provenance through `describe/2` |
| 6 | Run one reusable policy-port conformance suite; prove a `deny` decision issues no grant, that no operating-system process starts, and that the refusal is a committed durable fact the operator can read; prove the run continues or terminates truthfully after a denial and never retries the refused call; prove a policy that raises, times out, or returns a malformed value fails closed into denial rather than falling through to allow; prove `defer` is declared and refused in M2 rather than silently treated as allow or deny; prove every executor-backed tool including a `read_only` one requires a decision and that there is no read-only exemption; prove model output, tool metadata, IDs, injected context, and ordinary client input cannot mint or widen a grant; prove with the selector's own in-file fixture policies that a permissive policy applies only when it is named in configuration and that omitting the policy option refuses runtime start rather than falling back to permission, importing nothing from any client; separately, in the reference client's own lane, prove the shipped `Loopex.Policy.AllowAll` allows every decision it is asked and emits exactly one visible permissive-authority notice |
| 7 | Prove discovery resolves a deterministic canonical ordered zero-or-one project-resource set for a workspace, independent of filesystem enumeration order, and applies bounded shell, label, containment, declared-size, per-entry, and total byte checks before hashing or traversing a body already known to be inadmissible; declare and validate the class-total field while stating that M2's one permitted label and equal per-file/class-total byte ceilings make that comparison a future-shape guard rather than an independently reachable refusal branch; prove the operator is presented every resolved path, provenance and trust class, content digest, and manifest digest before deciding; prove the first exact matching positive decision binds canonical workspace identity, revision, resolved set, and digests, a changed value invalidates it, and no later or ambiguous decision can override the first match; prove a headless run with no matching positive decision stages the class empty, journals the exact declined receipt, and still runs the coding task, so failing closed withholds content and never runtime; prove a matching empty manifest is truthfully staged and distinct from no manifest; prove an admitted block changes no active tool set, policy decision, bound, or grant, and typed delimiters are input structure rather than an authority boundary; prove an ordinary workspace read stays a policy-governed tool effect and never enters proactive context staging; prove the exact final provider-visible messages and model-facing tool projections are charged under committed `loopex.context_bytes.v1`, while the exact final `model_request_committed` record is independently normalized, fixed-point sized, and measured under the Store ceiling; prove a trusted optional project block that alone exceeds either dimension is withheld whole with a compact receipt naming dimension, observation, limit, estimator, and ordered-descriptor digest, while required system, session, steer, or tool context overflow commits one bounded non-retryable failure and makes no provider call; prove no receipt repeats oversized content or private source identity and replay reproduces the same admission decision from durable values |
| 8 | Prove cancellation is an acknowledged two-phase protocol: session creation commits one positive unsigned-64-bit cleanup period in `session_genesis_v2`, recovery refuses a missing or conflicting value rather than substituting a process default, every canonical job carries it, and Core applies ADR 0016's checked exact formula once to derive executor observation, receipt retention, execute-result reserve, terminal reserve, session cache, and command backstop without legacy production waits or timer truncation; prove every long wait slices one monotonic deadline safely and a later phase receives only the remainder; prove prepared recovery transfers one opaque activation capability to the interrupt owner while ordinary recovered work remains paused, omission or mismatch authorizes nothing, and an admitted abort defeats later activation; prove abort admission commits before cleanup begins, scheduling stops immediately, and a separate ending commits only after the in-flight model call and executor job receive configured cooperative cancellation, the committed grace elapses, and the captured executor process group is terminated and confirmed quiescent or reported unconfirmed; prove the coordinator remains responsive, a second interrupt reports pending cleanup, and the command arms one liveness backstop then extends it once on accepted admission without reading timeout as a verdict; prove required executor `cancel/2` and the configured facade run outside the coordinator, and missing, malformed, raised, exited, timed-out, `{:ok, :unconfirmed}`, and `{:error, reason}` answers all normalize to unconfirmed rather than clean; prove every operation the run owns commits its own terminal fact before the run terminal, on live cleanup and recovery alike, and a Store refusal of that fact stops the owner rather than allowing an independently chosen run outcome; prove `cancelled` only where every operation is validated terminal and every captured executor process group confirmed quiescent, with every weaker state committing `outcome_unknown` and its reconciliation reference; prove a validated pre-abort tool fact is preserved, an unprovable effect is never blindly retried or overwritten by a later abort, and succession cannot report a clean stop for predecessor work it could not settle; prove the interrupt reaches the run through the public facade only, an aborted model response never becomes canonical, and the operator observes both what was requested and what actually happened |
| 9 | List sessions from a state root resolved from `LOOPEX_HOME` in a fresh operating-system process with no inherited runtime; prove the state root is never read from application environment; prove a session resumes under its creating `runtime_id`, that a different `runtime_id` is refused with an explicit reason, that a repeated resume command identity returns its historical result without advancing the owner epoch, and that a fresh identity acquires live ownership; prove the placement identity survives restart because it is persisted and re-presented rather than regenerated |
| 10 | Drive `run`, `sessions`, `resume`, `cancel`, and `artifact` end to end through the embedded API; prove `prompt`, `steer`, `follow_up`, and `abort` each have a distinct explicit affordance, that the operator steers a running task and queues a follow-up from the same terminal, and that input naming neither steer nor follow-up is refused rather than resolved from session state; prove tool progress emitted by a running executor job reaches the operator's terminal before that tool finishes; prove `artifact` retrieves a spilled artifact by the object locator carried in its compact reference and exact bytes come only through validated `stat` plus `fetch`; deliver a real interrupt signal to a real running command process and prove the task is cancelled through the public facade, that what was observed is printed, and that an interrupt whose cleanup cannot be confirmed reports `outcome_unknown` with its reconciliation reference rather than a clean `cancelled`; prove `cancel` against a live owner is refused by placement mutual exclusion with an explicit message and that against a dead owner it prepares ownership without scheduling ordinary work, transfers one opaque activation capability, and reconciles the session to a truthful terminal state before any activation can win; prove explicit cleanup or context configuration conflicts abandon the prepared owner with their exact weaker failure when confirmation is unavailable, while omitted values recover retained truth and settled sessions compare no active-run value; prove command replay is decided before current defaults are resolved; prove `--policy` selects the governing host policy and that a run under a refusing policy reports the refusal and continues or terminates truthfully; prove the project-resource trust decision is presented and taken at the terminal and that a non-interactive invocation without a decision runs with the project block withheld and the decline journaled rather than being refused; replace or instrument the facade so the test fails if any module of the command application reaches a coordinator, store, model, executor, artifact store, journal, outbox, or cursor internal, names a concrete Store, Model, Executor, or ArtifactStore implementation, or owns a second state machine, the host policy modules it ships for `--policy` being the single named exception because policy is the host's own decision; measure the base system prompt plus exact active model-facing tool projections with `loopex.context_bytes.v1` and require the result under one thousand estimated tokens before project context without claiming provider-tokenizer equality, capacity, billing, or an upper bound; prove `run` commits an explicit or reference-default context-admission budget and cleanup period, while configured prepared `resume` and `cancel` recover rather than replace them; prove one CLI liveness backstop is derived from that cleanup value, extended once after abort admission, and never interpreted as a commit verdict; prove argument parsing and terminal output use only the standard library and that the application declares no external dependency; prove no wire or line-framing contract is introduced; prove the consumer half of the closure contract by dropping a stream closure and asserting the terminal falls back to the durable record exactly as it does for a sequence gap, reads no absence as abandonment, and arms no timer to decide |
| 11 | Start the OTP application tree, a runtime, and a session, submit a prompt, and consume events using only the shipped `loopex_composition` application; measure its single composition module and require at most one hundred eighty effective lines, counting neither blank lines nor comments; prove an independent embedder fixture composes the kernel through that application without depending on the command application, so the wiring is a shipped dependency rather than a snippet each embedder copies and lets go stale; prove the composition names the concrete Store, Model, Executor, and ArtifactStore implementations, ships no policy of its own, requires and validates the host's policy and every other required host input before the first effect, and starts no runtime when any required input is absent or invalid, so no embedder inherits the command's permissive default or leaves a partial stack behind; prove the composition owns the Store, workspace lease, executor, and runtime processes it starts and releases them in reverse acquisition order after any later error, raise, or exit and after normal runtime stop or abnormal runtime death; prove the composition resolves its state root explicitly and reads none from application environment |

The ADR 0015–0018 cases are supporting contract roles rather than additional
operator outcomes. Artifact-runtime and artifact-retention roles protect the
object/use boundary behind Outcomes 5 and 10. store-item-budget,
context-admission, composition-context, and command-context roles protect the
two independent staging dimensions behind Outcomes 1, 3, 7, 10, and 11.
Provider-attempt and provider-adapter roles protect the permit,
classification, accounting, recovery, and stream-domain boundary behind
Outcomes 1 and 2. Cancellation-observation, local-authority, prepared-recovery,
and reference-cancellation
roles protect the common cleanup value and effect-admission truth behind
Outcomes 4, 8, 9, and 10. Each is included in `protected_executed`, carries an
exact floor and exact passed names in the gate, and fails on current product
behavior at the accepted Amendment 4 checkpoint. None may be counted as a
twelfth feature or substituted for an outcome's end-to-end evidence.

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

The declared tool schema carries a sibling obligation: evaluate required
members, scalar types, scalar-array item types, and string enums across the
registered subset before policy, grant, or job construction; admit undeclared
members only when they remain bounded JSON-like plain data; preserve fractional
JSON numbers through canonical staging, durable dispatch, and Store transaction
normalization.

**The governance machinery M2's own prerequisite rode on carries an obligation
of its own.** M2 could not be implemented before the M1 gate generation named
in Prerequisites, and exactly two corpora enforce that transaction:
`apps/loopex/test/status_check_test.exs`, which proves the status check's live
view of a Closed milestone's gate generations, and
`apps/loopex/test/history_anchoring_test.exs`, which proves the same across
reachable history. M2 locks both — `status_check_test.exs` at minimum 43 and
`history_anchoring_test.exs` at minimum 25 — and names between them the cases
that prove an unavailable walk is unavailable evidence in both history checks
and that a declared bound-artifact table binding nothing is refused, that the
real history reader carries the canonical register and refuses a laundered
prerequisite, that a completed Acceptance row is judged even while the
register still says Open, that a Closed milestone cannot conceal an outstanding
prerequisite behind an Open successor, and that accepting one later cannot
legalise an earlier acceptance, that a Closed milestone's gate is amended by an accepted generation
rather than a rebind, that a generation table fails closed on every malformed shape and
is append-only in both admitted directions, that the integrated phase is derived
from the register's closed rows, that a milestone cannot derive an Accepted or
later capsule while an ADR its plan pair declares as a prerequisite is still
Proposed, and that a generation rebind cannot bind an interposed, an
unrelated-byte, a merge, or a behind-a-merge revision. The obligation is that
those cases stay present and passing at those minima for the whole milestone.

The prerequisite case is here for the same reason as the rest. The three
decisions above must carry recorded acceptance before this plan pair and gate
are accepted, and the register is where that claim is read; before this
milestone, the derivations for Open, Accepted, In progress, and In review
discarded ADR statuses entirely, so `M2` would have derived "accepted and
implementation may proceed" the moment its own row moved, with all three
prerequisites still Proposed. The register now names the outstanding
dispositions while `M2` is Open and refuses to derive any later state until
every one of them is Accepted. `apps/loopex/test/m1_exunit_runner_test.exs` carries the same
obligation at minimum 5 for the same reason, and is additionally a bound
artifact whose bytes cannot change: it is the corpus proving the authoritative
result channel every outcome reports through cannot be spoofed, so a channel
bound without its corpus would be a digest without a meaning.

The reason is specific to this milestone rather than general tidiness. M0 locks
`history_anchoring_test.exs` at minimum 3 and cannot be reopened, and nothing
locked `status_check_test.exs` at all, so without these two rows the cases that
stop a closed gate being silently rebound could be deleted without tripping any
count. M2 is the milestone that rebinds a closed gate's bound artifacts. A
milestone that performs that transaction while letting the check on it rot would
be proving its own prerequisite with the mechanism it disabled, so the ratchet
is an evidence obligation here and not only a gate row.

Durable fault coverage stays structural, as M1 established. Every new logical
operation that can change durable session truth enters through one production
transaction dispatch, every executable transition phase carries a stable
`fault_point_id`, and evidence asserts set equality between the complete
declared, injected, and observed `{transition_id, fault_point_id}` key sets. A
new production transition without a derived injected and observed case fails
that equality assertion rather than silently escaping the catalogue.

Required mutation evidence is thirteen ordered, independently restored records in
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
9. Artifact object/use boundary / `artifact_use_object_binding` /
   `apps/loopex_store_local/test/artifact_store_conformance_test.exs`
10. Outcome 4 / `local_whole_root_replacement_refusal` /
   `apps/loopex_executor_local/test/local_authority_contract_test.exs`
11. Outcome 4 / `local_generation_copy_refusal` /
    `apps/loopex_executor_local/test/local_authority_contract_test.exs`
12. Context admission / `context_model_projection_accounting` /
    `apps/loopex/test/context_admission_test.exs`
13. Provider attempt authority / `provider_attempt_one_use_permit` /
    `apps/loopex/test/provider_attempt_protocol_test.exs`

The eighth record covers the milestone's headline structural claim. Introducing a
client application is exactly when "session before surface" is most at risk, so
the mechanism that fails a build where a second module reaches past the facade
carries a mutation record of its own rather than resting on source inspection
alone. No record stands in for two mechanisms, and a failure observed from a
dirty or previously mutated baseline is no evidence. These thirteen retained
records are representative non-vacuity evidence, not an exhaustion of ADR
0015–0018's clause-derived mutation obligations. Exact-SHA closure review maps
every required mutant family to a locked case and runs each selective mutant
from a clean green candidate; an unmapped clause, a surviving mutant, or an
unrelated failure blocks closure. Because the gate-first roles are deliberately
red at proposal A and rebind R, neither revision can honestly produce that
post-implementation mutation evidence.

Amendment 4's **pre-acceptance and first-green mutation manifest** in
[the gate](M2-gate.md#amendment-4) is part of this evidence obligation. Its
artifact/context, cancellation/Local, provider-attempt, and governed-evidence
rows are exhaustive for the clauses found by the pre-acceptance hunt, unlike the
thirteen representative retained demonstrations. A seam absent at proposal `A`
does not defer its row: the row becomes executable when its owning selector
first turns green and must be run, causally killed, exactly restored, and mapped
to retained exact-candidate output before closure. Adding the fault seam is
ordinary implementation only when it exposes no product authority or public
contract; otherwise implementation stops for the decision the new boundary
requires. No review may satisfy a row by source inspection, a fabricated
adapter that bypasses the owning boundary, an unrelated failure, or a test that
compares a value only with the source from which it was derived.

The named context fixture keeps two accepted measurements distinct. The
canonical list of four retained tool definitions is exactly 3,530 bytes and
1,177 estimator tokens. The accepted 4,382-byte and 1,462-token values are the
component-wise sum of the system message plus each full canonical tool
definition, the historical retained system-provenance measurement ADR 0017
cites. They are neither the definition-list encoding nor a marginal Store-record
fixed point. The fixture constructs every component independently and sums the
same estimator over those components.

Execution evidence has three non-self-referential full M2 captures — Darwin at
the exact floor pair, Darwin at the exact current pair, and Linux at the exact
current pair — plus one exact-candidate re-proof of the immutable M0 gate on
each locked pair and one exact-candidate re-proof of the complete M1 gate on the
current pair. Each capture starts from the same clean committed source
candidate `C`, runs the complete captured M2 command set except validation of
the record it is about to create, and emits one authoritative non-gate `CAPTURE`
record only after those commands pass. A capture never calls the ordinary gate
recursively, emits GREEN, or supplies merge evidence. Every capture and M0
re-proof uses fresh, disjoint build, dependency, temporary, `LOOPEX_HOME`,
workspace, and product-state roots; physical order and adjacency are inert.

The three captures, the attended demonstration record, and the real-call
attestations are committed in evidence commit `E`, the direct one-parent child
of `C`. `C→E` may change exactly `docs/evidence/M2-toolchain-matrix.md`,
`docs/evidence/M2-negative-demonstrations.md`,
`docs/evidence/M2-coding-demonstration.md`, and
`docs/evidence/M2-real-call-attestations.md`; every other tree byte is identical.
The ordinary gate runs at `E` on all three lanes and alone may emit final GREEN.
Closure transition `T` is the unique commit that first completes M2's canonical
Closure record and is the direct one-parent child of `E`. It changes only that
Closure row, the two canonical derived-status documents, and one new append-only
disposition in the durable context map. Every descendant of `E` passes through
`T`; the four evidence blobs, the Closure row, and that disposition remain
unchanged thereafter. Later product work and accepted gate generations are
ordinary descendants rather than reasons for a closed gate to turn red.

Mechanical and judgment authority stay separate, and the gate document
enumerates exactly what the runner checks so no reader infers more:

| Authority | Owns |
| --- | --- |
| `bash scripts/check-m2-gate.sh` | Bound artifact digests, protected and inherited selector identities, states and minima, locked command exit status, the matrix marker set, its single reachable candidate, its per-lane toolchain and platform fields, its cross-lane identity agreement, its seven self-describing digests against the files at candidate `C` that they name, its two M0 and one M1 exact-candidate gate re-proofs, the direct four-document `C→E` evidence edge, the direct four-document `E→T` closure edge, mandatory passage through `T`, and retention of evidence, Closure, and disposition thereafter; negative-demonstration record shape, key order, selector pairing, candidate-side tracked-path safety, and each restored digest against its own record candidate; real-call attestation record shape, role order, locked selector pairing, the declared identifier form and its agreement across records, identifier conformance to that declared form and non-reuse, agreement with the identity the bound runner sealed in the same run, and internal consistency of calls against identifiers and totals; the credential boundary, build-root isolation including the checkout's inert `_build`, and user-state containment |
| `mix loopex.status` | Live consistency among M2's governance rows, register state, root README status capsule, indexes, links, and the current revision's lifecycle claims, and every plan's declared bound artifacts against the working tree and reachable history |
| Independent review | Whether tests assert what their names promise, whether mutations, interrupts, and cancellations were honestly injected, whether one clean-baseline mechanism was disabled and caused each named failure, whether retained fields match actual captured process output, whether the attended demonstration was a genuine task rather than a scripted one, whether each retained provider response identifier and its reported usage exist in the provider account for the window claimed — the only step that reaches the provider, and the only one that can distinguish a real call from a well-formed fabrication — whether the provider-reported input-token count is retained and compared diagnostically with the named repository estimate without asserting tokenizer equality or an upper bound, whether the closure documents are current, and whether the operator experience satisfies the Purpose |

One canonical decimal gate seed from `0` through `999999` is supplied to every
M2 protected selector role, every inherited M1 selector role, the provider
default-exclusion control, and the ordinary final full suite in that gate run.
`protected_executed` is the sum of authoritative executed test counts across
M2's own locked roles — the eleven Outcomes, the supporting registry,
tool-schema, stream-mechanics, reference-bounds, artifact-runtime,
artifact-retention, store-item-budget, context-admission, composition-context,
command-context, provider-attempt, provider-adapter,
cancellation-observation, local-authority, prepared-recovery, and
reference-cancellation roles, and the
attended demonstration's two roles; a test reported excluded never
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

The composition is the reference stack wired, not a wiring toolkit, exactly as
Outcome 11 states it in the Concept envelope; this is the mechanics of that
limit, not an additional disclosure. It names four concrete implementations
behind a one-hundred-eighty-line ceiling, so an embedder depending on it transitively
acquires the reference adapters and their external dependency whether or not
every one is used, and an embedder choosing a different Store, Model, Executor,
or ArtifactStore cannot use it and composes the public ports and the `Loopex`
facade itself. That is acceptable while exactly one implementation of each port
exists, which is M2's whole inventory, and a wiring layer general enough to serve
both cases waits until a second real composition exists to give evidence for
one.

Every surface M2 touches is therefore unstable and may change without notice
until a milestone publishes one: the embedded Elixir API, the `loopex` command
surface, the composition application's entry point, the private journal and
store schema, the executor job and receipt protocol, the tool contract, the
policy port, and the artifact-store port.
`docs/developer/compatibility-surfaces.md` records that list and says plainly
that no label, deprecation window, or migration note is owed for any of them
yet. Internal process topology, process messages, and private structs are not
public API. No surface becomes a release candidate here, because none of them
has schemas, independent consumers, vectors, or migration evidence.

ADRs 0015–0018 still require exact compatibility truth on those unreleased
surfaces. ArtifactStore adapters make a source-breaking callback transition to
object-aware `fetch/2`, locator-only `stat/2`, and `describe/2`; old five-member
references have no trustworthy immutable use and fail unavailable, while object
bytes themselves need no migration. The executor boundary gains configured
cancellation and prepared recovery while legacy arities remain defensive only;
`JobRequest`, receipts, session genesis, status, and the Local ledger gain
versioned fields. Context admission writes `prompt_admitted_v2`, versioned
attachment snapshots, closed context receipts, and bounded failure projections.
The Model error detail remains source-compatible as `term()`, but an adapter that
does not return exact pretransport `not_dispatched` proof now receives the
stricter possibly-dispatched accounting and no-retry behavior. Private model
attempt opens and settlements are versioned and older development journals fail
closed rather than being interpreted under the new retry rule.

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

Rollback across ADRs 0015–0018 is atomic at their rejoin. Restore the prior
ArtifactStore facade and Local/session/context/provider schemas together; do not
leave the ADR 0016 receipt-fitting consumer with a five-member artifact
reference, do not retain a prepared-recovery caller against legacy cancellation,
and do not decode a new attempt or context record under an older reducer. The
content-addressed artifact object files may remain, but new use sidecars and
eight-member references are unavailable to the old runtime. A Local ledger root
is never downgraded or rewritten. Before activating prior code, every Local
instance, launch guard, captured process group, and other authority from the new
generation must be positively terminated; if that cannot be proved, the
operator reboots the host and starts the prior source with a fresh empty state
root while leaving the old root quarantined. This is an operator rollback
procedure, not a cross-root discovery or migration promise.

Every product checkpoint offered for review keeps the bootstrap aggregate, both
exact M0 lanes, and the complete M1 gate green while the M2 runner reaches its
next truthful missing-feature red. The historical M1 gate-generation window
named in Prerequisites was the one bounded exception: from the workstream E
commit that changed its two bound artifacts until generation revision `R` was
accepted and integrated, bootstrap, status, and the transitively affected M0
gate were red for that one stated reason and no checkpoint inside the window was
an integration candidate. That window is closed; it supplies no exception to a
current M2 checkpoint or closure candidate.

The accepted opening checkpoint defines the product bytes restored by rollback
for unintegrated M2 work. Rollback uses one or more descendant revert commits
that undo the product changes while preserving accepted ADRs, amendment
transactions, and reachable history; it never resets, rebases, or otherwise
rewrites the designated milestone branch. The resulting content restores the
accepted red condition without rewriting durable user data. After a complete M2
candidate first becomes green, each later checkpoint must keep M2 and both M0
lanes green or be repaired or reverted by descendant commits to the last
reviewed green content. Ordinary local red-green work between checkpoints is
not an integration candidate.

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
its next numbered amendment section and the v2 marker, its appended generation
row, and both rebound artifacts together, and a child `R` that completes that
row's authority, evidence, and the candidate it binds. It never shares a
revision with an M2 plan amendment.

No M2 product implementation merges while M2 is red or before closure. No
rollback claim extends to a data root written by a different source revision.

<a id="technical-plan-packaging"></a>
### Packaging

Concept: [Milestone scope](M2.md#concept-plan-scope).

No package is published or installed, and no version is tagged. ADR 0001's
umbrella direction and ADR 0002's runtime floor are unchanged.

The planned inventory becomes exactly eight applications with exact roles:
`loopex_protocol` as `:contract`, `loopex` as `:core`, `loopex_store_local`,
`loopex_llm_reqllm`, and `loopex_executor_local` as `:edge`,
`loopex_composition` as `:composition`, and `loopex_reference_client` and
`loopex_cli` as `:client`. The role rules are:

- `:contract` declares no dependency of any kind, in any environment;
- `:core` declares exactly one production dependency, `:loopex_protocol`, and no
  external, edge, composition, or client dependency in any environment;
- `:edge` declares a production dependency on `:loopex`, may also depend on
  `:loopex_protocol`, and imports no concrete sibling adapter;
- `:composition` declares a production dependency on `:loopex`, may also depend
  on `:loopex_protocol`, declares production dependencies on the in-umbrella
  `:edge` applications it composes, may declare no external dependency in any
  environment, and may depend on no `:client` and on no other `:composition`;
- `:client` declares a production dependency on `:loopex`, may declare a
  production dependency on at most one `:composition`, may declare in-umbrella `:edge` dependencies only in tests
  exactly as M1 already permitted, may declare no external dependency, and may
  not depend on another `:client`.

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
emitting the same single permissive-authority notice. The composition supplies no
policy of its own and must not close that gap: it ships no policy at all, takes
the host's as a required argument, and starts no runtime without one, because a
permissive default living in shared wiring would be inherited by every embedder
that depends on the wiring. Two reference hosts each naming their own policy is
the ownership ADR 0009 describes.

This changes the repository's own dependency check. `mix loopex.deps_budget` and
its source, `apps/loopex/lib/mix/tasks/loopex.deps_budget.ex`, are product code
this milestone edits: the planned inventory grows from six named applications to
eight, the role set gains `:composition`, and the client rule gains its single
composition dependency. Its adversarial corpus in
`apps/loopex/test/deps_budget_test.exs` grows three cases, raising its locked
minimum from M1's 25 to 28 — one for the eight-application inventory, one for
the `:composition` role's own permitted and forbidden directions, and one for
the client rule that admits at most one composition and still no second client.
The minimum rises by three rather than two because a new role is not the same
adversarial claim as the rule that consumes it: a corpus that proved only the
client side would leave a composition free to declare an external dependency or
to depend on a client. Both files are bound by the closed M1 gate, which is why
the amendment in Prerequisites is a prerequisite rather than a note, and they
are the only two artifacts that generation rebinds: the inventory and role
change is stated in them and needs no third bound artifact. The M2 gate does not bind either file's
bytes, because binding bytes the milestone must change would lock a digest
acceptance already knows is wrong; it locks the command and both corpus
identities instead. The M0 gate locks the command without binding its bytes and
must still pass.

`loopex_llm_reqllm` remains the only application permitted a direct external
dependency, exactly `{:req_llm, "~> 1.17.1"}` without source options. Core
remains Elixir/Erlang standard-library and OTP only. `loopex_composition`
declares production dependencies on `:loopex`, `:loopex_store_local`,
`:loopex_llm_reqllm`, and `:loopex_executor_local`, and no external dependency
in any environment. `loopex_cli` declares production dependencies on `:loopex`
and `:loopex_composition` and nothing else in any environment; its argument
parsing, signal handling, and terminal output are standard library and OTP
only.

The operator entrypoint is an `escript`. `apps/loopex_cli/mix.exs` declares an
`escript` main module, `mix escript.build` produces an executable named `loopex`
in that application, and `loopex --version` reports the single version train's
value. The escript must build and run on all three locked lanes. Because an
escript starts with no application tree, the shipped composition — now in
`loopex_composition`, reached through the command's single composition
dependency — is responsible for starting one — `:ssl`, the HTTP client stack `req_llm` pulls in, telemetry,
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

**The command surface is a client application, and the composition is not a
boundary either.** Neither defines a behaviour, a callback, or a replaceable
implementation. `loopex_composition` exists for exactly one module, in the only
production application permitted to depend on the concrete `:edge`
applications, and that module has a hard ceiling: at most one hundred eighty effective lines, counting neither blank lines
nor comments, measured by a protected test. The measured implementation uses
164 effective lines, leaving a sixteen-line margin. The earlier eighty-line
ceiling left the processes started before a later failure or runtime exit
ownerless; explicit ownership and reverse cleanup are part of the reference
stack rather than optional scaffolding. The ceiling remains the executable form
of the vision's requirement that one page of code can start a runtime, create a
session, submit a prompt, and consume events. It is high enough to express
lifecycle ownership without compression hiding work, and still low enough to
refuse a configuration language, generic component graph, or duplicated runtime
behavior.

**One `mix.exs` and one role rule is what shipping it costs, and what it buys.**
An application is more machinery than a module in an existing one, so the
addition is justified rather than assumed: the composition must be depended on
by a client and reachable the same way by an embedder, no existing role may be
depended on that way
without weakening a rule that is load-bearing elsewhere, and the alternative —
one page each embedder copies — is re-derived once per embedder and drifts
silently the first time the kernel's start-up shape changes. A shipped
application makes that drift a compile error in every dependant instead. A
second `:composition` application stays forbidden, and the planned application
inventory `mix loopex.deps_budget` enforces is what forbids it.

**The reference prompt has one measured ceiling.** The base system prompt plus
the active built-in tool definitions must measure under one thousand estimated
tokens before project context. The measurement is deterministic and
dependency-free: a documented estimator over the exact UTF-8 bytes, with a
recorded identity and version, asserted by a protected credential-free test,
and reported whether it passes or fails. It is a repository admission policy,
not a claim to reproduce or upper-bound a provider tokenizer. A measurement that
needs a tokenizer dependency is out of budget. The attended real-provider
demonstration record additionally reports the provider's own input-token count
for the same prompt, which review compares diagnostically with the estimate; it
is not a second gate-enforced
ceiling, because the bound `scripts/m1-exunit-runner.exs` seals a fixed
real-path field set and cannot carry an additional field without amending an
immutable artifact.

**Explicitly forbidden in this milestone,** whether or not something would find
them convenient: a transport behaviour, a daemon, a socket, a wire protocol or
line framing, a controller lease, a broker, a policy engine, a generic event
bus, a plugin macro system, a context-provider or transformer registry, an
alternate session engine, a second `:composition` application, a terminal
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
