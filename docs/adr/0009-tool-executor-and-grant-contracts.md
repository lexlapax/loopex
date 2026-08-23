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
the exact definition generation it used.

The v0.1 rung raises the stakes rather than the polish. `read`, `write`, `edit`,
and `bash` run against a developer's real repository. A policy seam that can
only return `allow` is not a permissive default — it is the absence of the
decision point, and adding one after the tools ship means retrofitting it under
every call site that already assumed success. Equally, `M1` commits an abort
durably and then does nothing with it: the coordinator has no abort handling, so
an aborted run's owned model call and owned OS process keep running. The vision
requires that cancellation stop owned work and report what was observed; `M1`
implemented the recording half and none of the stopping half.

These are one decision because they share one path. A tool definition supplies
the identity a grant binds, host policy decides whether that grant exists, the
executor validates it, and cancellation is what makes the resulting effect
stoppable and its outcome truthful. Deciding any one of them alone would fix the
others by implication without evidence.

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
- **Every tool call records the definition generation it resolved.** Resolution
  happens once per call, before argument validation and before host policy is
  asked. The resolved generation is journaled with the tool-operation intent and
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
- **Failure and malformed input deny; they never fall through to allow.** A
  policy timeout, crash, unknown return, or malformed decision resolves to a
  denial with an unavailability category. There is no configuration that turns a
  policy error into an allow.
- **Interactive `defer` is deferred with a named acceptance point.** The port's
  contract names `defer` so no successor has to widen it, and an `M2` policy
  that returns `defer` is refused fail-closed as a denial rather than executed.
  The durable suspended interaction, exact-response matching, expiry, and
  resume-after-restart evidence that make `defer` honest are a prerequisite of
  the durable-service milestone, which is where multi-client attachment supplies
  the evidence.
- **The core has no default policy, and `AllowAll` is a named, visible reference
  choice.** Starting a runtime with effectful tools and no configured policy is
  refused. The reference CLI may select the documented `AllowAll` policy for a
  trusted local developer, must name it in configuration rather than inherit it,
  and must state on use that this is permissive local authority and not a
  permission model.
- **Nothing but a policy `allow` mints a grant.** Model output, tool metadata,
  the registry entry, a definition digest, prompt text, project resources, and
  client arguments transport no authority. This restates ADR 0007's boundary in
  the shape `M2` gives it and changes none of its ten bindings, its final
  pre-start validation boundary, its one digest identity, or its independent
  oracle.
- **Cancellation stops owned work and reports what was observed.** A durably
  admitted abort stops scheduling new work, cooperatively cancels the in-flight
  model or executor operation, waits a declared bounded grace period, then
  terminates the owned process tree. Terminal truth follows the vision's
  cancellation algebra exactly: an already-validated `completed`, `failed`, or
  `denied` fact is preserved; `cancelled` commits only after confirmed cleanup
  evidence; an effect that cannot be proved ends `outcome_unknown` and reaches
  ADR 0007's receipt and reconciliation path unchanged. The run finishes
  `cancelled` in each case and never feeds a late tool result back to the model.
  An aborted run reaches a terminal outcome without operator intervention.
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
Tool definitions, policy decisions, and cancellation records are ordinary
session-domain content written by the one serial session owner under the same
owner-epoch and journal-version fencing, and the registry is runtime-scoped
state that adds no placement claim.

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
a milestone's worth of work whose natural evidence arrives with multi-client
attachment. Deferring it is safe only because an unimplemented `defer` denies
rather than allows.

**A per-tool boolean allowlist in configuration instead of a policy port.** It
is smaller and it would satisfy the immediate need to say no. It is not
recommended: it is a policy language pretending to be configuration, it cannot
express the per-call facts that matter — which path, which command, which effect
class — and it relocates authority from the host into Loopex, which the
ownership map forbids.

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

Cancellation costs are concrete and platform-shaped. The executor must capture
process-group and kill identity before it accepts an effectful job, which makes
the accept path heavier and ties it to POSIX process semantics; no Windows claim
is made. Confirmed cleanup before committing `cancelled` also means an abort is
not instantaneous, and the declared grace period is a visible operator-facing
value rather than a hidden constant.

The registry is a new core concept and must justify itself against the
minimalism budget. It unifies four concrete built-in definitions today, it is
the exact seam §14.3 requires, and direct code cannot express "the generation
this request validated against" without it. It stays in core because the
identity it owns is the identity a grant and a journal bind; everything above it
— profiles, search tools, extension-supplied tools — stays outside.

Technical depth: [Operational consequences](0009-tool-executor-and-grant-contracts-technical.md#technical-adr-0009-consequences).

<a id="concept-adr-0009-compatibility"></a>
## Compatibility, Migration, and Rollback

No released surface exists and no installed base exists. Version 0.1.0 is a
tagged source version with no Hex publication, so nothing about a tool schema,
policy contract, or grant shape is promised across versions, and the
compatibility contract's freeze machinery is not engaged.

`M1` journals are not migrated. `M1`'s two demonstration tools are removed
rather than renamed, because renaming them would imply a continuity of meaning
that never existed, and `M1`-owned test roots are discarded.

Rollback before closure removes the registry, the four bootstrap tools, the
policy port, and the cancellation path together, returning the runtime to
`M1`'s single-tool option. There is no partial rollback that keeps the registry
and drops the policy port, because the grant path depends on both, and none
that keeps cancellation without the executor's process-ownership capture. After
0.1.0 is tagged, changing a built-in's `tool_id`, effect class, or parameter
schema is a new version of that definition rather than an edit to the old one.

Technical depth: [Format, migration, and rollback mechanics](0009-tool-executor-and-grant-contracts-technical.md#technical-adr-0009-compatibility).

## Links

- [ADR 0007](0007-local-executor-grant-job-receipt.md#concept) — the grant, job,
  and receipt contract this decision supplies identities for and does not change
- [ADR 0010](0010-provider-continuation-and-context-staging.md#concept) — the
  paired decision that turns a tool result into the next turn's context
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
