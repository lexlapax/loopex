# 0009: Technical depth

<a id="technical-depth"></a>
## Technical depth

Concept: [Tool, executor, and grant contracts](0009-tool-executor-and-grant-contracts.md#concept).

<a id="technical-adr-0009-context"></a>
## What M1 Supplies and What the Tool Surface Requires

Concept: [Context](0009-tool-executor-and-grant-contracts.md#concept-adr-0009-context).

The gap is mechanical, not stylistic. Each row below is a requirement the
technical vision already states, next to what the closed `M1` product actually
provides.

| Requirement | `M1` today | Why the gap matters |
| --- | --- | --- |
| Tool IDs and versions resolve through a runtime-scoped registry | Two function clauses in the local executor, one fixed `tool_version` constant | There is no resolution step, so there is nothing to make runtime-scoped and nothing a second definition could conflict with |
| A request records the exact definition generation it used | The session holds one `tool` map from runtime options | The journal cannot say which schema accepted an argument, so replay cannot reproduce validation |
| Explicit conflict rules | None | Two definitions claiming one identity is currently unrepresentable rather than refused |
| Host policy owns `allow`, `deny`, `defer` | The literal term `{:host_policy, :allow}`, validated to be exactly that | There is no decision point; every reachable path ends in a grant |
| Failure never falls through to allow | Vacuous — there is no failure path | A property with no reachable counterexample is untested |
| Cancellation stops owned work | Abort is admitted and journaled; the coordinator never reads it | The model call and the OS process both keep running after an acknowledged abort |
| Bounded output, path containment, edit preconditions, shell semantics, process ownership, artifact spill | The two demonstration tools write a fixed bounded file | No shared behaviour exists to conform to |

The second column is not a defect in `M1`. `M1`'s purpose was durability, and a
one-tool loop with a literal allow was the smallest thing that let the grant,
job, and receipt path be proved. It becomes a defect the moment `bash` and
`edit` run against a developer's repository, because the properties above stop
being unreachable and start being the ones a user relies on.

The `tool_id`, `tool_version`, and `effect_class` bindings ADR 0007 validates
are the exact point of contact. Today the executor compares them against a
constant it owns, so the comparison is real but the identity is trivial. This
decision gives that identity a source without changing the comparison.

<a id="technical-adr-0009-decision"></a>
## Exact Definition, Registry, Behaviour, and Cancellation Contract

Concept: [Decision](0009-tool-executor-and-grant-contracts.md#concept-adr-0009-decision).

### Tool definition and definition generation

A definition is a bounded plain-data record:

```text
tool_id                  bounded ASCII, dot-segmented, "loopex." reserved
tool_version             semantic version, exact string
name                     model-visible name
description              bounded model-visible text
parameter_schema         declared JSON Schema-compatible subset
result_shape             model-facing normalized result descriptor
effect_class             read_only | workspace_write | process | external_effect
idempotency_class        safe_retry | reconcile_then_retry | never_blind_retry
budgets                  declared wall time, output bytes, and artifact ceilings
```

It carries no function, module atom, pid, port, reference, or host concept, and
the whole record round-trips through the store and the executor protocol as
plain data.

The declared schema subset is fixed by this decision so that a subset extension
is a visible change rather than a coincidence of whatever the first provider
accepted: object root with named properties, a required-name list, and property
types drawn from string, integer, number, boolean, and array-of-those, each with
an optional description and an optional string enumeration. Nested objects,
unions, references, and conditional keywords are refused at registration. The
subset is expressed as ordinary Elixir maps and lists; no JSON codec is
introduced, and none is available at the accepted Elixir 1.17 and OTP 26 floor.

Canonicalization sorts map keys by their binary value, encodes the record in the
protocol-versioned canonical encoding already used for the request digest, and
digests the result. The definition generation is:

```text
{tool_id, tool_version, definition_digest}
```

Equal digests never admit different bytes: the registry retains the exact
canonical bytes and compares them, not only the digest.

### Registry contract

The registry is a runtime-scoped structure reached only through the explicit
runtime reference that already carries the store, executor, and model
configuration. Its operations and outcomes are:

| Operation | Outcome |
| --- | --- |
| `register(runtime, definition)` where the generation is new | `:ok`, definition retained |
| `register` with an identical `tool_id`, `tool_version`, and canonical bytes | `:ok`, no state change |
| `register` with the same `tool_id` and `tool_version` and different bytes | `{:error, :tool_definition_conflict}` |
| `register` with a new `tool_version` of a known `tool_id` | `:ok`, admitted additively |
| `register` under the `loopex.` prefix from outside the reference distribution | `{:error, :reserved_tool_namespace}` |
| `resolve(runtime, tool_id)` | highest registered semantic version at resolution time |
| `resolve(runtime, tool_id, tool_version)` | that exact generation, or `{:error, :unknown_tool_generation}` |
| `resolve` for an unregistered `tool_id` | `{:error, :unknown_tool}` |

There is no unregistration and no in-place replacement in `M2`. The active set
offered to the model is a bounded list of generations selected at session start
and committed with the session, so a registration that happens mid-run cannot
change what the current run may call.

Conformance for the runtime scoping is direct: start two runtimes in one VM with
disjoint tool sets and prove that each resolves only its own, that neither
observes the other's conflict, and that no registered name, application
environment key, or persistent term is created for a tool identity. That last
part is proved by inspection of the process registry and the application
environment rather than asserted.

### Resolution and recording

Per tool call, in this order:

1. Resolve the generation named by the model's call against the run's committed
   active set. An unresolvable name is a terminal `failed` tool call with reason
   `unknown_tool`; it is never guessed and never dispatched.
2. Validate arguments against that generation's `parameter_schema`. A validation
   failure is a terminal `failed` tool call with a bounded diagnostic and no
   policy consultation.
3. Ask host policy, with the resolved generation, the validated arguments, the
   effect class, and the workspace lease reference.
4. On `allow`, journal the tool-operation intent including the generation
   triple, then build the `JobRequest` and grant that ADR 0007 governs.

The generation triple is part of the canonicalized job fields, so it is covered
by the single `canonical_request_digest` and needs no second digest. The
executor's existing `tool_id`, `tool_version`, and `effect_class` binding
comparisons are unchanged; their expected values now come from the recorded
generation rather than from an executor-owned constant.

### The seven shared behaviours

Each rule below is normative for every bootstrap tool and is exercised by one
port-level conformance suite, so an isolated or remote hand later runs the same
cases without editing them.

**Bounded output.** Every tool declares a model-facing byte ceiling. Output at
or below the ceiling is returned whole. Output above it is truncated at a UTF-8
code point boundary at or below the ceiling, the model-facing result carries an
explicit truncation marker with the original byte length, and the untruncated
bytes are retained as an artifact. A tool never returns unbounded bytes, and
truncation is never silent.

**Workspace-root resolution.** Every path argument is resolved against the root
named by the workspace lease. An absolute path is admitted only when it is
inside that root. A relative path is joined to the root and then containment is
checked. Path metadata alone never grants access; the lease does.

**Symlink and path-scope containment.** Containment is decided on the fully
resolved real path at the moment of use, not on the lexical path. A component
that is a symlink whose target resolves outside the root is refused. Where the
platform cannot guarantee that the resolved path and the used path are the same
object, the tool opens the resolved target and operates on that handle rather
than re-resolving the name, and refuses when it cannot. The refusal reason names
path containment rather than the target, so a probe cannot use refusals to map
the filesystem outside the root.

**Exact edit preconditions.** `edit` applies only when the supplied expected
bytes occur exactly once in the current file content. Zero matches and two or
more matches are both refusals whose diagnostic reports the observed count and
nothing derived from a guess. The file's content is read and matched inside the
same operation that writes it; no edit is applied to content the tool did not
just observe.

**Explicit shell-versus-argv semantics.** `bash` takes an explicit mode. In argv
mode it receives a program and an argument list and no shell is involved; in
raw-shell mode it receives one program string and an explicitly named shell. The
mode is a field of the call, never inferred from metacharacters in the string. A
call that supplies an argument list in raw-shell mode, or a program string in
argv mode, is refused rather than reinterpreted.

**Process ownership.** Before the executor accepts an effectful job it captures
the kill identity of the process it will own — on POSIX, its own process group —
and retains it with the job. Cleanup terminates the whole owned descendant tree
and confirms termination before any `cancelled` fact commits. `M2` claims POSIX
process semantics only and makes no Windows claim.

**Artifact spill.** Bytes above the model-facing ceiling become an immutable
artifact with a digest and a bounded reference. The reference, never the bytes,
enters model context. The artifact is pinned for the operation's retry and
recovery window so a receipt that names it stays reconstructable.

### Host policy port

```text
@callback decide(request :: policy_request()) ::
            {:allow, policy_context :: term() | nil}
            | {:deny, reason_category()}
            | {:defer, interaction_request()}
```

`policy_request` is bounded plain data: session and run identity, the resolved
generation triple, validated arguments, effect class, idempotency class, and the
workspace lease reference. It carries no pid, no credential, and no provider
value. The returned `policy_context` is opaque to Loopex and is transported into
the grant exactly as ADR 0007 already permits, uninterpreted.

`reason_category` is a closed enumeration — at minimum `policy_denied`,
`effect_class_not_permitted`, `workspace_not_permitted`,
`interaction_unsupported`, and `policy_unavailable` — so no free host text
reaches model context through a denial.

Fail-closed resolution is exhaustive:

| Observation | Resolution |
| --- | --- |
| `{:allow, context}` | grant issued under ADR 0007 |
| `{:deny, category}` | durable denial, `denied` tool call, no dispatch |
| `{:defer, _}` in `M2` | `{:deny, :interaction_unsupported}` |
| Callback raises, exits, or times out | `{:deny, :policy_unavailable}` |
| Any other return shape | `{:deny, :policy_unavailable}` |
| No policy configured and any effectful tool active | runtime start refused |

A denial commits before it is reported, so an aborted or crashed coordinator
cannot lose the fact that a call was refused, and the `denied` outcome is the
validated terminal fact the cancellation algebra must preserve.

`Loopex.Policy.AllowAll` lives in the reference client rather than in core, must
be named explicitly in configuration, and emits one visible notice on use. A
selector proves that omitting the policy option refuses runtime start rather
than defaulting to it.

### Cancellation

The sequence implements the vision's acknowledged cancellation protocol without
adding to it:

```text
abort admitted and committed (already M1 behaviour)
  -> coordinator stops scheduling new work for the run
  -> cooperative cancel to the in-flight model task or executor job
  -> declared bounded grace period elapses
  -> executor terminates the owned process tree by its captured kill identity
  -> cleanup confirmed
  -> operation: retain a validated completed / failed / denied fact
              | cancelled when cancellation caused termination
              | outcome_unknown when effect evidence is insufficient
  -> run: cancelled
```

Ordering follows the committed journal. If a validated completion commits before
abort admission, the abort is acknowledged as already terminal. If abort
admission commits first, no new work is scheduled and any later evidence is
handled only through that operation kind's reconciliation rules. A late executor
receipt for a cancelled run is retained truthfully and is not projected into the
next model turn, because there is no next turn. `outcome_unknown` reaches ADR
0007's reconciliation path unchanged, including its solicited-response and
fencing requirements.

The grace period is a declared session configuration value with a default and is
reported in the terminal outcome's evidence, so an operator can distinguish a
clean cooperative stop from a forced kill.

### Evidence

Claim-proportional evidence for this decision:

- registry conflict, idempotent re-registration, additive versioning, reserved
  namespace, and unknown-generation resolution, each with its exact reason;
- two runtimes in one VM with disjoint tool sets, plus inspection proving no
  VM-global name or application-environment key was created;
- a recorded generation that survives a restart and is used for validation and
  dispatch after recovery, with a registry changed in between;
- one shared behaviour suite run against all four bootstrap tools, including
  refusal cases for escape by absolute path, escape by relative traversal,
  escape by symlinked component, zero-match and multi-match edits, mode misuse
  in `bash`, ceiling-crossing output with artifact spill, and descendant process
  cleanup;
- policy conformance covering allow, deny, defer-in-`M2`, timeout, crash, and
  malformed return, each asserting the exact resolution above and asserting that
  no job was dispatched for every non-allow case;
- refusal to start a runtime with effectful tools and no configured policy;
- abort during a model call and abort during an executor effect, each proving
  owned work stopped, cleanup confirmed, the terminal fact truthful, and no late
  result projected into model context;
- the retained prompt and schema cost measurement for the bootstrap four, which
  is the deferred profile decision's input.

<a id="technical-adr-0009-alternatives"></a>
## Alternative Analysis

Concept: [Alternatives](0009-tool-executor-and-grant-contracts.md#concept-adr-0009-alternatives).

**Fixed code-owned tool table.** Cheapest by a wide margin at four tools. It
fails the recording requirement rather than the ergonomic one: with no
generation there is nothing to journal, so a replayed operation validates
against whatever the code says today. That is invisible while there is one
version of everything and silently wrong on the first change. Retrofitting it
during the extension milestone means introducing resolution at the same moment
namespaced contributions, activation ordering, and rollback arrive.

**All seven tools now.** No technical obstacle; three more schemas and three
more conformance runs. The objection is evidentiary. The vision makes the
reference profile evidence-selected precisely because prompt cost, shell
avoidance, and task utility trade against each other, and a profile shipped
before measurement is a default nobody chose. The three deferred tools also
compete for the same 1,000-token reference budget the paired decision must hold.

**`defer` in `M2`.** The full port is more honest than two thirds of it. It also
requires a durable interaction record with its own identity and idempotency,
exact-response matching that rejects stale, duplicate, expired, and mismatched
responses, expiry that interacts with cancellation, and resume-after-restart
proof — and a client flow to answer it. That is a milestone, and its evidence is
natural once multiple clients can attach. The fail-closed mapping is what makes
the deferral safe: an `M2` policy that returns `defer` denies, so no code path
treats an unimplemented decision as permission.

**Configuration allowlist instead of a port.** A map of tool identity to boolean
would let a host say no today. It cannot express the per-call facts that decide
real cases — this path, this command, this effect class, this workspace — so
every real host would immediately need an escape hatch, and the escape hatch is
the port. It also places the decision inside Loopex, contradicting the ownership
map's assignment of authorization to the host.

**Signed or portable grants.** Unchanged from ADR 0007: `M2` still has one
machine, one attached caller, and an in-VM executor, so a signature would secure
a boundary that is not crossed. The first isolated or remote hand is the trigger.

**Parallel tool batches.** Filesystem mutations, shells, and compilers do not
commute, and the vision requires a declared conflict set, per-batch cancellation
semantics, and source-order persistence before any batch runs concurrently.
`M2` executes serially and claims nothing else.

<a id="technical-adr-0009-consequences"></a>
## Operational Consequences

Concept: [Consequences](0009-tool-executor-and-grant-contracts.md#concept-adr-0009-consequences).

### If accepted

- Definition canonicalization joins the protocol-versioned digest surface.
  Changing key ordering, encoding, or the schema subset changes every recorded
  digest, so it becomes a versioned change with fixtures rather than an edit.
- Journals retain each referenced definition's canonical bytes. Session size
  grows by the active set once per session rather than once per call, which is
  small, but it is permanent and it constrains compaction: a compaction that
  discards definition bytes breaks replay validation.
- Extension activation inherits a constraint. Activation may add generations and
  may stop offering one to the model, but it may not make a recorded generation
  unresolvable for a session whose journal names it. That is a real limit on the
  rollback design, and it is better discovered here than during activation work.
- Denial reasons enter model context. The closed category keeps that channel
  narrow. The consequence is that hosts cannot explain a denial to the model in
  their own words, which will be felt as a limitation and is the intended trade.
- The executor's accept path becomes heavier and platform-specific. Capturing
  process-group identity before accepting a job is required for honest cleanup
  and ties the local executor to POSIX semantics.
- Abort becomes bounded rather than instantaneous. Operators see a grace period
  and, in the worst case, an `outcome_unknown` that requires reconciliation
  rather than a comfortable false `cancelled`.

### If rejected

- The registry's absence leaves `tool_id` and `tool_version` bindings that are
  validated against a constant, so ADR 0007's oracle stays green while proving
  nothing about resolution.
- Without a policy port, the first real `bash` against a real repository ships
  with no reachable refusal, and any later port must be threaded through call
  sites written on the assumption that authority always exists.
- Without cancellation, an acknowledged abort leaves an owned OS process running
  and a run with no terminal outcome, which contradicts a founding requirement
  and makes the durability work `M1` closed less useful rather than more.

<a id="technical-adr-0009-compatibility"></a>
## Format, Migration, and Rollback Mechanics

Concept: [Compatibility, migration, and rollback](0009-tool-executor-and-grant-contracts.md#concept-adr-0009-compatibility).

The durable format gains the active-set record committed at session start, the
per-call generation triple on each tool-operation intent, the durable denial
record, and the cancellation evidence retained with a terminal outcome. All are
bounded plain data in the session mutation domain and none crosses into a public
plane except through the existing bounded tool-call events.

There is no installed base and no published package. Version 0.1.0 is a tagged
source version, so the tool definition shape, the policy callback, the reason
categories, and the active-set record are all experimental and freeze nothing.
`M1` journals are neither read nor migrated, and `M1`-owned test roots are
discarded rather than upgraded.

Rollback before closure removes the registry, the four bootstrap tools, the
policy port, the denial record, and the cancellation path together, and returns
the runtime to the `M1` single-tool option. Partial rollback is not available:
the grant path depends on both resolution and policy, and cancellation depends
on the executor capturing kill identity at accept time. After the 0.1.0 tag,
changing a built-in's `tool_id`, effect class, or parameter schema is a new
`tool_version` under the additive registration rule; the old generation stays
resolvable for any journal that names it. Removing a reason category, widening
the schema subset, or making `defer` executable each require a successor
decision, because each changes what a recorded decision meant.
