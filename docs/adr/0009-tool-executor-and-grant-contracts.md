# 0009. Tool, executor, and grant contracts

<a id="concept"></a>
## Concept

Technical depth: [Definition, registry, behaviour, and policy mechanics](0009-tool-executor-and-grant-contracts-technical.md#technical-depth).

- **Status:** Proposed
- **Date:** 2026-08-23
- **Decision owner:** Maintainer
- **Prerequisite for:** `M2` acceptance

## Governance Record

| Decision | Authority | Authority evidence | Bound bytes |
| --- | --- | --- | --- |
| Acceptance | — | — | — |

<a id="concept-adr-0009-context"></a>
## Context

`M1` closed a real durability kernel. It did not close a tool surface. The
executor exposes exactly two hardcoded function clauses, `loopex.demo.write` and
`loopex.demo.wait_write`, and a session receives exactly one of them as a plain
map in runtime options. There is no registry, no version resolution, and no rule
for what happens when two definitions claim one identity. Authority is the
literal term `{:host_policy, :allow}` handed to the runtime at start: there is
no path by which a host can say no, and none by which it can ask.

[ADR 0007](0007-local-executor-grant-job-receipt.md#concept) already fixed what
the executor validates. Its grant binds `tool_id`, `tool_version`, and
`effect_class`, and its independent oracle fails if any of the ten bindings is
dropped. What 0007 deliberately did not decide is where those three values come
from. In `M1` they come from a two-clause function that cannot disagree with
itself, so the bindings are correct and prove nothing about resolution. The
moment a runtime holds more than one definition, "the version of that tool's
definition" needs an owner, and §14.3 of the technical vision names one: a
runtime-scoped registry with explicit conflict rules, and a request that records
the exact definition generation it used. Resolution has a second half `M1` never
had to face: a provider call names a tool by its model-visible name, and with one
tool in the options there was never a name to look up.

The v0.1 rung raises the stakes rather than the polish. `read`, `write`, `edit`,
and `bash` run against a developer's real repository. A policy seam that can
only return `allow` is not a permissive default — it is the absence of the
decision point, and adding one after the tools ship means retrofitting it under
every call site that already assumed success. Equally, `M1` commits an abort
durably and then does nothing with it: the coordinator has no abort handling, so
an aborted run's owned model call and owned OS process keep running. The vision
requires that cancellation stop owned work and report what was observed; `M1`
implemented the recording half and none of the stopping half.

Oversized output has the same shape of gap. The two demonstration tools write a
fixed small file, so nothing has ever exceeded a ceiling. `bash` running a test
suite exceeds one on its first real invocation, and §12.6 of the technical
vision assigns that overflow to an `ArtifactStore` port that no application
currently owns. Spill is not a rendering nicety: the bytes that do not reach the
model still have to exist somewhere addressable, because a receipt that names
them must stay reconstructable.

These are one decision because they share one path. A tool definition supplies
the identity a grant binds, host policy decides whether that grant exists, the
executor validates it, oversized output leaves that path through the artifact
seam, and cancellation is what makes the resulting effect stoppable and its
outcome truthful. Deciding any one of them alone would fix the others by
implication without evidence.

Technical depth: [What M1 supplies and what the tool surface requires](0009-tool-executor-and-grant-contracts-technical.md#technical-adr-0009-context).

<a id="concept-adr-0009-decision"></a>
## Decision

- **A tool definition is immutable, versioned, plain boundary data.** It carries
  a stable `tool_id`, a semantic `tool_version`, the model-visible name and
  description, a parameter schema drawn from a declared JSON Schema-compatible
  subset, the model-facing result shape, one `effect_class` from the vision's
  four, one idempotency class, and declared budgets. It contains no function,
  module, pid, or host concept. Its canonical bytes have a digest, and the
  triple of `tool_id`, `tool_version`, and that digest is the **definition
  generation**.
- **The model-visible name is unique, and a session binds exactly one active
  generation to it.** A provider call names a tool by its model-visible name, not
  by `tool_id`, so the name is what a model's call actually has to resolve and
  resolving by internal identity alone would leave the real lookup undefined. A
  session commits one name-to-generation mapping together with its active set at
  start, and every call for that run resolves through that one mapping. Two
  active generations claiming one name — two versions of a `tool_id`, or two
  different `tool_id`s — refuse session start as a conflict rather than being
  ordered, preferred, aliased, or silently renamed, because a silent winner would
  let a later selection change which code a familiar name reaches. `tool_id`,
  `tool_version`, and the digest remain the durable identity a grant and a
  journal bind; the name is a per-session presentation binding and carries no
  authority.
- **Every tool call records the definition generation it resolved.** Resolution
  happens once per call, from the model-visible name through the run's committed
  mapping, before argument validation and before host policy is asked. The
  resolved generation is journaled with the tool-operation intent and
  is covered by the canonical request digest ADR 0007 binds. Validation and
  dispatch use that recorded generation for the life of the operation, so a
  registry change cannot alter an in-flight operation's semantics.
- **The registry is runtime-scoped and reached only through the explicit runtime
  reference.** No VM-global registered name, no application environment, no
  process dictionary or persistent term keyed by tool identity alone. Two
  runtimes in one VM hold independent tool sets and neither can observe or
  displace the other's.
- **Registration is append-only for a runtime's lifetime, with one conflict
  rule.** Re-registering an identical `tool_id`, `tool_version`, and canonical
  digest is idempotent and changes nothing. The same `tool_id` and
  `tool_version` with different canonical bytes is refused as a conflict. A new
  `tool_version` of an existing `tool_id` is admitted additively. `M2` has no
  unregistration and no replacement; namespaced replacement through a trusted
  extension contribution stays where [ADR 0003](0003-extension-contract-boundary.md#concept)
  left it. The `loopex.` identity prefix is reserved for the reference
  distribution.
- **The bootstrap four ship: `read`, `write`, `edit`, and `bash`.** They are the
  minimum that closes the vision's five verbs, because `bash` can express search
  and navigation while `grep`, `find`, and `ls` cannot express mutation or
  execution.
- **`M1`'s two demonstration tools are retained as registered generations and
  excluded from every active tool profile.** `loopex.demo.write` and
  `loopex.demo.wait_write` keep their exact identities, versions, and behaviour,
  because `M1`'s locked protected case for the credential-free OS tool and its
  retained receipt must keep passing unchanged and a renamed or deleted tool
  would break it. They are registered like any other definition and are never
  members of the active set a session offers a model, so no legacy fixture
  reaches a real conversation. Nothing in the reference distribution selects
  them; only a test composition does.
- **`grep`, `find`, and `ls` are deferred with a named acceptance point.** They
  are not implemented in `M2` and the reference default profile stays unfixed.
  `M2` must retain the measured prompt and schema cost of the bootstrap four as
  evidence; the `coding_search` profile and the reference default require a
  successor decision informed by that measurement plus observed shell-avoidance
  and task utility, and that decision must be accepted before any milestone
  publishes a reference tool profile or claims the seven-tool surface.
- **Seven shared behaviours are normative and share one conformance suite.**
  Bounded output, workspace-root resolution, symlink and path-scope containment,
  exact edit preconditions, explicit shell-versus-argv semantics, process
  ownership, and artifact spill each get an exact rule rather than an
  implementation habit. Every bootstrap tool runs the same suite, and the suite
  is written against the executor port so a later isolated or remote hand runs
  it unchanged.
- **Host policy becomes a real port; `M2` implements `allow` and `deny`.** The
  literal `{:host_policy, :allow}` term is replaced by a `Loopex.Policy`
  callback consulted once per resolved tool call, with bounded plain data,
  before the tool-operation intent commits. `deny` commits a durable denial,
  produces a truthful `denied` terminal fact for that tool call, returns a
  bounded closed-category reason to the model, and dispatches nothing.
- **Every executor-backed tool call takes a policy decision, `read_only`
  included.** There is no effect class, no tool, and no argument shape that
  skips the port. A `read` is still an effect: it crosses the executor boundary
  under a workspace lease, reads bytes out of a real repository, and puts them
  into model context and therefore into a provider request, and which workspace
  and which path a host will permit is a host decision by the same ownership rule
  that makes a write one. The stronger reason is structural: "effectful" is not a
  predicate anything can evaluate identically twice. It would have to be decided
  somewhere, its false branch would be a dispatch path with no policy call on it,
  and every later tool would arrive arguing about which side of the predicate it
  sits on. A universal decision point has no false branch to audit.
- **A policy decision carries bounded plain data in both directions.** The
  request is bounded plain data, and so is anything an `allow` returns for the
  grant to transport: a bounded opaque host reference the host itself resolves,
  plus a small bounded map of serializable scalars. No arbitrary Erlang term
  crosses the port in either direction, so a host cannot put a pid, a function, a
  credential, or an unbounded structure into a grant that ADR 0007 retains and an
  executor keeps. A return outside that shape is malformed and denies.
- **`Loopex.Policy` is a fourth product boundary behaviour, and it is a narrow
  host-control port rather than a replaceable infrastructure port.** Store,
  Model, and Executor each replace a mechanism; Policy replaces nobody's
  mechanism, because §6.4 of the technical vision assigns the decision itself to
  the host and Loopex owns only the seam. It is admitted as a port and not as a
  configuration option for one reason: the decision it carries is per call, and
  a host that cannot see this path, this command, and this effect class cannot
  make it. It unifies two concrete implementations in `M2` — the documented
  permissive local policy the reference command names, and the refusing policy
  the negative-authority selectors drive — and it is what a hosted product
  supplies without forking core. It runs the reusable policy conformance suite
  §23.2 already requires of every policy adapter.
- **Oversized tool output leaves through a fifth behaviour, `ArtifactStore`,
  with the smallest local adapter.** The artifact-spill rule below cannot be
  honest without a place to put the bytes, and §12.6 assigns that place to a
  port whose adapter and host own location, encryption, access control,
  retention, and collection. **`M2` ships exactly one adapter**: a filesystem
  adapter that writes digest-addressed immutable objects under the resolved
  state root. It is what the reference composition wires, what an embedder
  gets, and what runs the reusable artifact-store suite §23.2 already requires.
  The in-memory implementation is **a test-only fixture and not a second
  shipped adapter**: it exists so core tests need not touch a real state root,
  it lives in the test lane, and it is neither product surface nor package
  surface. No reader should conclude that `M2` ships two adapters — it ships
  one adapter and one fixture, and only the adapter is supported, documented,
  or composable by a host. Direct
  code is insufficient because the bytes are produced at the hand and referenced
  by the brain: a hand that later runs in isolation or on another machine must
  spill through its own adapter without changing what the receipt means. The
  port is reached through an explicit reference supplied at composition, never a
  global name, and no application depends sideways on another edge to obtain it.
- **An artifact reference is bounded plain data and the bytes never re-enter
  context implicitly.** A reference carries the content digest, media type,
  size, and logical role plus an opaque retrieval reference, exactly as §12.6
  requires. `M2` ships no model-facing tool that reads an artifact back; that
  tool belongs to the same successor decision that fixes the reference tool
  profile, so the model cannot defeat the output ceiling by reading its own
  spill.
- **Failure and malformed input deny; they never fall through to allow.** A
  policy timeout, crash, unknown return, or malformed decision resolves to a
  denial with an unavailability category. There is no configuration that turns a
  policy error into an allow.
- **Interactive `defer` is deferred with a named acceptance point.** The port's
  contract names `defer` so no successor has to widen it, and an `M2` policy
  that returns `defer` is refused fail-closed as a denial rather than executed.
  The durable suspended interaction, exact-response matching, expiry, and
  resume-after-restart evidence that make `defer` honest must be accepted before
  the headless session-protocol milestone claims the interaction request and
  response round trip its transport contract already lists, and that milestone
  is where the round trip first has a client on the other end of it.
  Multi-client attachment in the daemon milestone then supplies the reconnect
  and takeover cases, not the first evidence.
- **The core has no default policy, and the permissive policy is a named,
  visible host choice.** Starting a runtime with any executor-backed tool active
  and no configured policy is refused. `Loopex.Policy.AllowAll` ships in the
  reference client, the `:client` application that is Loopex's reference host,
  and not in the trusted-local executor edge. Hosts own policy: a permissive
  default is a host's decision to trust its own workspace, so it belongs to the
  reference host that makes it. An edge that shipped a permissive policy would
  hand that decision to every embedder that composes the trusted-local executor,
  which is exactly the relocation of authority into Loopex the ownership map
  forbids, and it would also travel to the first isolated or remote hand as an
  inherited `AllowAll`. Nothing in an edge imports it: the executor edge's
  deny and refusal selectors define their own fixture policies in their own test
  file, so no application depends on a `:client` to reach one. It must be named
  explicitly in configuration, is never an implicit fallback, and emits one
  visible notice stating that this is permissive local authority and not a
  permission model.
- **Nothing but a policy `allow` mints a grant.** Model output, tool metadata,
  the registry entry, a definition digest, prompt text, project resources, and
  client arguments transport no authority. This restates ADR 0007's boundary in
  the shape `M2` gives it and changes none of its ten bindings, its final
  pre-start validation boundary, its one digest identity, or its independent
  oracle.
- **`M2` admits cancellation in process, through the public facade.** The abort
  command is submitted on the same attachment the run was submitted on, by the
  same operating-system process, and the reference command's own interrupt
  handler is what submits it when an operator presses Ctrl-C. This is not a
  stylistic choice: `M2` has no daemon, no socket, and no second client, and
  [ADR 0008](0008-owner-succession-recovery-and-runtime-placement.md#concept)
  permits one live Runtime Control per Store identity and `runtime_id`, so a
  second operating-system process cannot reach the live coordinator at all.
  Cancelling a run from another process — and therefore any command surface that
  offers to stop a session it is not itself running — requires the daemon
  milestone's socket transport and controller model. Nothing about the algebra
  below depends on which process admitted the abort.
- **Cancellation stops owned work and reports what was observed.** A durably
  admitted abort stops scheduling new work, cooperatively cancels the in-flight
  model or executor operation, waits a declared bounded grace period, then
  terminates the owned process tree. Terminal truth follows the vision's
  cancellation algebra exactly: an already-validated `completed`, `failed`, or
  `denied` fact is preserved; `cancelled` commits only after confirmed cleanup
  evidence; an effect that cannot be proved ends `outcome_unknown` and reaches
  ADR 0007's receipt and reconciliation path unchanged. A cancelled run never
  feeds a late tool result back to the model.
- **The run's committed absolute deadline rides on every executor job, and a
  job's effective deadline is the earlier of that instant and the tool's own
  declared wall-time budget.** A run that advertises a wall-clock bound has to
  hold that bound over the work it owns, not only over its model calls.
  Every `JobRequest` therefore carries the absolute deadline instant
  [ADR 0010](0010-provider-continuation-and-context-staging.md#concept) commits
  with the run, and the effective bound on the job is the minimum of that
  instant and the instant the tool's declared wall-time budget implies — never
  the tool budget alone. Without the minimum, a long `bash` dispatched shortly
  before expiry outlives the bound its run advertised, and the bound is a claim
  about model calls wearing the name of a run-wide guarantee. This is a
  `JobRequest` field, not an eleventh grant binding: ADR 0007's `expiry`
  authorizes a job to *start* and its ten bindings are unchanged, while the job
  deadline bounds how long a started job may *run*. A tool call whose run
  deadline has already passed is not dispatched at all — no tool-operation
  intent commits, no grant is minted, and the call takes a terminal `cancelled`
  fact with no owned process tree to clean up.
- **A job that reaches its effective deadline is cancelled and cleaned up by
  the machinery an abort already uses, and its truth follows the same
  algebra.** At expiry the executor cooperatively cancels, waits the declared
  grace period, terminates the owned process tree by its captured kill
  identity, and confirms termination. A deadline-terminated job ends
  `cancelled` only after confirmed cleanup; where the effect or the cleanup
  cannot be proved it ends `outcome_unknown` and reaches ADR 0007's receipt and
  reconciliation path unchanged. Expiry introduces no second cancellation path,
  no second grace period, and no second terminal algebra, so there is nothing
  for the two paths to disagree about. The evidence obligation this creates is
  a real long-running executor job that crosses its deadline, with confirmed
  process-tree cleanup and a truthful terminal fact; the accepted plan and gate
  own the selectors that carry it.
- **The run outcome can say unknown too, and it must whenever the tool outcome
  did.** A run finishes `cancelled` only when every operation it owned reached a
  validated terminal fact and every owned process tree was confirmed cleaned up.
  If any owned operation ends `outcome_unknown` — an unprovable effect, or a
  process tree whose termination could not be confirmed within the grace period —
  the run finishes `outcome_unknown` carrying that reconciliation reference, and
  the operator-facing surface reports it as unknown rather than as a stop. A run
  that reported a clean `cancelled` over an effect nobody could prove would be
  the exact false comfort the unknown outcome exists to prevent, and it would
  leave the reconciliation the tool outcome demands with no visible reason to
  perform it. Both outcomes are terminal and immutable, and an aborted run
  reaches one of them without operator intervention. The same precedence holds
  whatever asked the run to stop. A run stopped by its deadline rather than by
  an operator commits the `bound_reached` outcome
  [ADR 0010](0010-provider-continuation-and-context-staging.md#concept) defines
  only when every owned operation reached a validated terminal fact and every
  owned process tree was confirmed cleaned up; an unprovable effect or an
  unconfirmed tree finishes that run `outcome_unknown` instead.
  `outcome_unknown` outranks `cancelled` and `bound_reached` alike, because an
  unprovable effect reported as a clean bounded stop is the same false comfort
  in a different word.
- **`M2` adds no external dependency and no JSON codec.** Parameter schemas are
  plain Elixir data in the declared subset. Wire encoding belongs to the
  provider adapter at the edge, never to the core and never to the reference
  client, which as a `:client`-role application may carry no external dependency
  at all. The accepted floor of Elixir 1.17 and OTP 26 forecloses `:json` and
  `JSON`, and this decision does not reopen
  [ADR 0002](0002-bootstrap-runtime-floor.md#concept).
- **`M2` still makes no authenticity claim.** The grant remains a structured
  value produced and consumed inside one trusted VM. The claim is that a wrong
  binding is refused and that a denied call never dispatches. Unforgeability,
  tamper evidence, transport safety, and OS isolation are not claimed by any
  document.

This decision changes nothing in
[ADR 0006](0006-store-transaction-and-owner-epoch.md#concept) or
[ADR 0008](0008-owner-succession-recovery-and-runtime-placement.md#concept).
Tool definitions, policy decisions, artifact references, and cancellation
records are ordinary session-domain content written by the one serial session
owner under the same owner-epoch and journal-version fencing, and the registry
is runtime-scoped state that adds no placement claim. The policy and artifact
references are composition inputs held beside the existing Store, Model, and
Executor references; neither is discoverable by name and neither carries
placement authority.

Technical depth: [Exact definition, registry, behaviour, and cancellation contract](0009-tool-executor-and-grant-contracts-technical.md#technical-adr-0009-decision).

<a id="concept-adr-0009-alternatives"></a>
## Alternatives

**Keep the code-owned fixed tool table.** Four built-ins fit in a case
statement, and the registry is genuinely more machinery than four clauses need
today. It is not recommended: a fixed table has no definition generation, so a
request cannot record what it validated against, replay cannot prove which
schema accepted an argument, and §14.3's conflict rule has nowhere to live. The
seam would then be retrofitted during the extension milestone, under the load of
namespaced contributions and activation ordering, which is the worst moment to
introduce it.

**Resolve model calls by `tool_id`, or by name with a precedence rule.** Using
`tool_id` alone is the smaller contract, and letting the highest version or the
last selection win a name collision never refuses anything. Neither is
recommended. A provider call carries a model-visible name, so `tool_id`-only
resolution leaves the actual lookup undefined and pushes an ad-hoc name mapping
into whichever adapter builds the request first. A precedence rule is worse than
a refusal: it makes the code a familiar name reaches depend on selection order,
which is invisible in a transcript and changes under an operator's feet the first
time a profile or an extension adds a second claimant.

**Ship all seven tools now.** This is tempting because the seven are already
named and none is hard. It is not recommended for `M2`: the vision makes the
reference profile evidence-selected, and shipping all seven before the
measurement makes the measurement decorative. Three more schemas also spend the
prompt budget
[ADR 0010](0010-provider-continuation-and-context-staging.md#concept) has to
hold, and spend it before anything has measured what `bash` already covers.

**Implement `defer` in `M2`.** This is the honest full shape of the policy port
and a hosted product needs it. It is not recommended here: a suspended
interaction needs a durable interaction record, exact-response matching, expiry,
abort interaction with cancellation, and resume-after-restart evidence, which is
a milestone's worth of work whose first client-side evidence arrives with the
headless session protocol. Deferring it is safe only because an unimplemented
`defer` denies rather than allows.

**A per-tool boolean allowlist in configuration instead of a policy port.** It
is smaller and it would satisfy the immediate need to say no. It is not
recommended: it is a policy language pretending to be configuration, it cannot
express the per-call facts that matter — which path, which command, which effect
class — and it relocates authority from the host into Loopex, which the
ownership map forbids.

**Consult policy only for effectful tools and let read-only tools through.** It
saves a decision per `read` and it matches an intuition that reading is harmless.
It is not recommended: the intuition is wrong, because a read crosses the
executor boundary under a workspace lease and moves repository bytes into model
context and out to a provider, and the classification is worse than the exemption
it grants. Whatever computes "effectful" becomes an authority-bearing predicate
inside Loopex, and its false branch is a dispatch path with no policy call on it
— which is precisely the shape an unpoliced path takes when someone later
declares one more tool cheap enough to skip.

**Let an `allow` return an uninterpreted host term for the grant to carry.** It
is the most flexible thing the port could offer and it asks nothing of hosts. It
is rejected rather than weighed: durable and executor-facing contracts carry
bounded serializable data, and an arbitrary term would put a pid, a function, a
closure over host state, or an unbounded structure into a grant that is retained,
digested, and validated. A bounded opaque reference gives a host the same
indirection without moving anything Loopex cannot canonicalize.

**Ship `AllowAll` in the trusted-local executor edge.** The executor already runs
with the user's own operating-system authority, so a permissive policy beside it
looks like a matched pair, and it would keep every policy selector in one
application. It is not recommended: policy belongs to the host, and an edge that
ships a permissive policy makes that host decision on behalf of every embedder
who composes that executor, including one that never wanted it. The dependency
worry that motivated the placement is not real — the executor edge's deny and
refusal selectors need a refusing fixture and a permissive fixture, both of which
are three lines in the test file, and neither needs the shipped client module.

**Spill oversized output into the private journal or straight onto the local
store's files instead of an `ArtifactStore` port.** It is the smallest possible
change and it needs no new behaviour. It is not recommended: it makes the
journal grow with test logs and build output, which is exactly what §12.6
separates, and it hard-codes the assumption that the process producing the bytes
can write the brain's storage. That assumption is false the first time a hand
runs in isolation or on another machine, and by then every receipt in every
retained journal names a reference whose meaning would have to change.

**Ship the artifact seam as a helper module in core rather than a port.** A
plain module with two functions would satisfy `M2` completely, since `M2` has
exactly one place bytes are produced. It is not recommended because the second
implementation is not speculative: §23.2 already lists artifact-store adapters
among the adapters that must run a reusable conformance suite, and the hosted
retention, encryption, and access-control duties §12.6 assigns are host duties
that a core helper would have to grow into. The suite is the part that makes it
a port; without it the behaviour would be one implementation wearing a
behaviour's clothes.

**Ship the in-memory artifact store as a second supported adapter.** The code
exists either way, it is the cheapest adapter imaginable, and an embedder
running an ephemeral or test workload would plausibly reach for one. It is not
recommended for `M2`. A shipped adapter is a support and package obligation: it
must be documented, kept conformant, and carried through every later change to
the port, and a store that loses every artifact on restart is the wrong thing
for anyone to find while reaching for a default. One shipped local adapter is
what this milestone's scope authorizes, and a test fixture that is honestly
labelled a fixture costs nothing and promises nothing. Promoting it to a
supported adapter later is additive; unshipping one that hosts have composed is
not.

**Delete or rename `M1`'s demonstration tools.** Renaming would give them
identities that suggest continuity, and deleting them is superficially tidier
than carrying two fixtures forward. It is not recommended: `M1`'s locked
protected case starts one credential-free operating-system tool and asserts its
retained receipt, and that case names these exact identities. Retaining them as
registered generations that no active profile offers keeps the inherited
protected behaviour green without letting a fixture reach a real conversation.

**Let a second operating-system process admit an abort by writing to the
Store.** It would give `M2` a `cancel` command that works from another terminal
today. It is rejected rather than weighed: the session coordinator is the sole
serial writer of that session's durable truth, a second writer would need the
owner epoch it cannot hold, and ADR 0008 already refuses two live Runtime
Controls over one Store identity and `runtime_id`. Cross-process cancellation is
a transport and controller problem, and it is solved where the transport and the
controller exist.

**Finish every aborted run as `cancelled`.** One terminal outcome for one
operator gesture is simpler to explain, simpler to render, and it is what an
operator pressing Ctrl-C expects to see. It is not recommended: it would make the
run outcome unable to express what the tool outcome already knows, so a run whose
owned process tree could not be proved dead would report the same clean stop as
one that was proved dead. The vision's algebra ends a run `cancelled` or
`outcome_unknown` for that reason, and the run outcome is the one an operator
reads.

**Bound an executor job by its tool budget alone and let the run deadline cover
model calls only.** This is the smaller contract and it is what a per-tool
budget already expresses: each tool declares how long it may run, and the run
deadline stops the loop between turns. It is not recommended, and it is the
defect this revision closes. The two budgets are independent, so a `bash` whose
declared budget is ten minutes, dispatched one minute before a run's deadline,
runs nine minutes past the instant the run advertised as its wall-clock bound —
with the run unable to finish, because it still owns an operation. A bound that
holds over one kind of owned work and not the other is not a run bound; taking
the minimum costs one propagated field and reuses the cancellation machinery
that already exists.

**Make the job deadline an eleventh grant binding.** The grant is already the
validated envelope for a job's authority, it already carries `expiry`, and one
more binding would put the deadline where the executor's fail-closed validator
would check it for free. It is rejected rather than weighed. ADR 0007's ten
bindings are a locked set with an independent completeness oracle, and widening
that set is a change to an accepted decision rather than an addition to this
one. The semantics differ too: `expiry` is validated once at the final pre-start
boundary and authorizes a job to *start*, while the deadline governs how long a
started job may *run* and must therefore be live for the job's whole life. Two
different questions in one field would make an expired grant and an exhausted
deadline indistinguishable in a refusal.

**Commit the run's bounded stop when the deadline fires and clean up
afterwards.** It makes the terminal outcome prompt, which is what an operator
watching a clock expects, and cleanup would still happen. It is not
recommended, and it is the same mistake as reporting `cancelled` over an
unproved effect: a committed `bound_reached` says the run stopped where it was
configured to stop, and a run whose owned `bash` is still alive has not stopped.
Waiting for confirmed cleanup costs the operator the declared grace period and
buys the outcome its meaning; where cleanup cannot be confirmed the honest
answer is `outcome_unknown`, not a faster `bound_reached`.

**Signed or portable grants, and OS isolation, in `M2`.** Not recommended and
not reopened: ADR 0007 already placed both at the first isolated or remote hand,
and `M2` crosses no boundary a signature would protect.

**Parallel tool execution.** Not recommended: the vision requires serial
execution by default and makes parallelism a separately evidenced feature with a
declared conflict set. `M2` makes no parallel claim.

Technical depth: [Alternative analysis](0009-tool-executor-and-grant-contracts-technical.md#technical-adr-0009-alternatives).

<a id="concept-adr-0009-consequences"></a>
## Consequences

The definition digest becomes part of the canonical request digest, so tool
definition canonicalization becomes protocol-versioned truth on the day the
first journal is written. Changing it later changes every digest and therefore
requires a version tag and fixtures rather than an edit. This is permanent.

Recorded generations must stay resolvable for replay. A runtime whose journals
reference a definition can never silently lose it, which constrains the
extension activation and rollback design that arrives later: activation may add
generations and may stop offering one to the model, but it may not make a
recorded generation unresolvable. Retaining each definition's canonical bytes
rather than only its digest is the cost that buys replayability, and it is a
permanent per-session storage cost.

A working `deny` makes refusal a model-visible outcome for the first time. The
denial reason therefore enters model context, which is why the reason is a
closed category rather than free host text: a host that could write arbitrary
strings into a denial would have an unaudited channel into the model's context,
and a model that reads a denial must still be unable to change what is allowed.

Deferring `defer` means `M2` cannot honestly claim a permission model, only
refusal. Every document must say so, in the same way ADR 0007's narrow security
claim must stay narrow. Deferring `grep`, `find`, and `ls` leaves real
measurement debt: if it is never paid, the reference profile gets chosen by
inertia rather than by evidence, which is exactly the outcome the vision's
evidence-selected profile exists to prevent.

Consulting policy for every executor-backed call, `read_only` included, is a
permanent per-call cost on the hot path of the cheapest tool there is, and every
host implementation now has to answer a read as well as a write. That cost is
accepted because the alternative is a classification inside Loopex whose false
branch dispatches without asking anyone.

Cancellation costs are concrete and platform-shaped. The executor must capture
process-group and kill identity before it accepts an effectful job, which makes
the accept path heavier and ties it to POSIX process semantics; no Windows claim
is made. Confirmed cleanup before committing `cancelled` also means an abort is
not instantaneous, and the declared grace period is a visible operator-facing
value rather than a hidden constant. It also means Ctrl-C has two honest endings
rather than one: an operator can be told the run stopped, or told the run's owned
effect could not be proved and names a reconciliation reference. Every surface
that renders a run outcome must render the second one, and no document may claim
that aborting a run guarantees a clean stop.

Carrying the run deadline on every job makes an executor job's lifetime a
property of the run rather than of the tool. A tool's declared wall-time budget
becomes a ceiling that the run can lower but never raise, so a tool author can
no longer reason about a job's maximum duration from the definition alone, and
an operator who shortens a run deadline shortens every tool call inside it. The
visible cost is that a long `bash` near the end of a run is cancelled with work
in progress rather than allowed to finish, and the run reports a bounded stop
only once that cancellation is confirmed — so a deadline is not instantaneous
for the same reason an abort is not. The compensating property is the one the
bound is for: the wall-clock number an operator declares is the number the run
actually respects, over model calls and over OS processes alike.

Unique model-visible names become part of what a session commits. The mapping is
journaled with the active set, so replay resolves the exact name the run used,
renaming a tool between sessions is free, and renaming one inside a session is
not possible. The refusal on a duplicate name is a real constraint on later
profile and extension work: two contributors who both want the name `search` will
find out at session start rather than by discovering which one won.

Two new boundary behaviours are a permanent widening of what an embedder must
supply and what every future adapter must satisfy. A host now composes five
references rather than three, two more conformance suites must stay green in
every lane, and the reference composition module has two more lines it cannot
drop. That cost is accepted because the alternative in each case relocates a
host duty into core: a policy expressed as configuration would put
authorization inside Loopex, and an artifact helper inside core would put
retention, encryption, and access control there too. Neither port may grow a
second responsibility later without a successor decision, because the narrowness
is the whole justification.

Retaining `M1`'s demonstration tools costs two definitions that will never be
offered to a model and one rule — active profile membership — that must be
enforced rather than assumed. The alternative was breaking an inherited
protected case, which is not available. The rule earns its keep beyond the
fixtures: it is the same rule that will keep an extension-contributed generation
out of a session that did not select it.

The registry is a new core concept and must justify itself against the
minimalism budget. It unifies four concrete built-in definitions today, it is
the exact seam §14.3 requires, and direct code cannot express "the generation
this request validated against" without it. It stays in core because the
identity it owns is the identity a grant and a journal bind; everything above it
— profiles, search tools, extension-supplied tools — stays outside.

Technical depth: [Operational consequences](0009-tool-executor-and-grant-contracts-technical.md#technical-adr-0009-consequences).

<a id="concept-adr-0009-compatibility"></a>
## Compatibility, Migration, and Rollback

No released surface exists and no installed base exists. `M2` tags no version:
`VERSION` stays `0.0.0` and the first version number is reserved for the
headless session-protocol milestone. Nothing about a tool schema, a model-visible
name, the policy contract, an artifact reference, or a grant shape is promised
across versions,
and the compatibility contract's freeze machinery is not engaged by anything in
this decision.

`M1` journals are not migrated and `M1`-owned test roots are discarded. `M1`'s
two demonstration tools are retained at their exact identities and versions,
because an inherited locked protected case names them; they are registered
generations that no active profile offers, so retention costs two fixtures and
changes no conversation.

Rollback before closure removes the registry, the four bootstrap tools, the
policy port, the artifact port, the job deadline, and the cancellation path
together, returning
the runtime to `M1`'s single-tool option. There is no partial rollback that
keeps the registry and drops the policy port, because the grant path depends on
both; none that keeps cancellation without the executor's process-ownership
capture; none that keeps the job deadline without that same cancellation path,
because expiry has nothing to terminate the owned tree with; and none that keeps
the bounded-output rule without the artifact port,
because truncation without a spill target loses bytes a receipt claims. Once a
version is published, changing a built-in's `tool_id`, effect class, or
parameter schema is a new version of that definition rather than an edit to the
old one.

Technical depth: [Format, migration, and rollback mechanics](0009-tool-executor-and-grant-contracts-technical.md#technical-adr-0009-compatibility).

## Links

- [ADR 0007](0007-local-executor-grant-job-receipt.md#concept) — the grant, job,
  and receipt contract this decision supplies identities for and does not change
- [ADR 0010](0010-provider-continuation-and-context-staging.md#concept) — the
  paired decision that turns a tool result into the next turn's context
- [ADR 0011](0011-session-input-algebra-and-streaming.md#concept) — the input
  algebra that admits the abort this decision acts on, and the transient
  progress plane a running tool reports through
- [ADR 0006](0006-store-transaction-and-owner-epoch.md#concept) — the
  transaction and owner-epoch contract these records are written under
- [ADR 0008](0008-owner-succession-recovery-and-runtime-placement.md#concept) —
  the succession and placement contract the runtime-scoped registry preserves
- [ADR 0003](0003-extension-contract-boundary.md#concept) — where namespaced
  tool replacement and extension contribution stay deferred
- [Vision tools and the coding surface](../vision-technical.md#technical-vision-tools) — tool definition, the seven-tool surface, registry and resolution
- [Vision ownership and trust](../vision.md#concept-vision-ownership-trust) — host-owned authority and the policy boundary
- [AGENTS.md](../../AGENTS.md) — authority grants, trust boundaries, plain
  boundary data, and the smallest sufficient system
