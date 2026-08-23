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
| A provider call resolves the model-visible name it was given | One tool map in runtime options; the name is whatever that map says and is never looked up | With one tool there is nothing to resolve, so no rule exists for the name a real provider call actually carries |
| Host policy owns `allow`, `deny`, `defer` | The literal term `{:host_policy, :allow}`, validated to be exactly that | There is no decision point; every reachable path ends in a grant |
| Failure never falls through to allow | Vacuous — there is no failure path | A property with no reachable counterexample is untested |
| Cancellation stops owned work | Abort is admitted and journaled; the coordinator never reads it | The model call and the OS process both keep running after an acknowledged abort |
| Bounded output, path containment, edit preconditions, shell semantics, process ownership, artifact spill | The two demonstration tools write a fixed bounded file | No shared behaviour exists to conform to |
| Oversized output becomes an artifact with a digest and a retrieval reference | Nothing produces oversized output, so nothing stores it | Bounded output is a promise to keep the bytes the model does not see; with no store behind it, it is a promise to lose them |
| An abort reaches the live coordinator | `Loopex.command/2` on the attachment that submitted the run | Correct for one in-process caller and unreachable from any other process, which is a limit to state rather than a gap to close here |

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
## Exact Definition, Registry, Behaviour, Artifact, and Cancellation Contract

Concept: [Decision](0009-tool-executor-and-grant-contracts.md#concept-adr-0009-decision).

### Tool definition and definition generation

A definition is a bounded plain-data record:

```text
tool_id                  bounded ASCII, dot-segmented, "loopex." reserved
tool_version             semantic version, exact string
name                     model-visible name, ^[a-z][a-z0-9_]{0,63}$
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

`name` is inside those canonical bytes, so changing a tool's model-visible name
produces a different digest and therefore a different generation. A rename is a
new `tool_version` under the additive registration rule, never an edit to a
registered one. The character set is narrower than `tool_id`'s on purpose: it
sits inside the tool-name constraints of the providers this milestone targets,
which is a claim `M2` checks against each adapter it ships rather than assumes,
and a dot-segmented `tool_id` is not portable as a provider tool name at all.

### Model-visible names and the session name mapping

A provider request lists tools by `name` and a model's tool call names one back.
`tool_id` never appears on that wire, so name resolution is the real lookup and
this decision specifies it rather than leaving it to whichever adapter builds a
request first.

Names are unique per active set, not per registry. The registry may legitimately
hold `read` at `1.0.0` and `read` at `2.0.0`, and a namespaced extension
contribution may later register a second `tool_id` whose definition also calls
itself `read`. Neither is a registration conflict, because neither is yet offered
to a model.

Composition of the active set at session start therefore does three things in
order:

1. Resolve each selected entry to one generation.
2. Build the name mapping `name -> {tool_id, tool_version, definition_digest}`.
3. Refuse the session if any name is claimed twice, with
   `{:error, {:duplicate_tool_name, name}}` naming both claiming generations.

There is no precedence, no ordering rule, no last-writer-wins, and no automatic
disambiguation suffix. The refusal is at composition, before any provider request
is built, so a session either has an unambiguous mapping or does not start.

The mapping is committed with the active-set record and is immutable for the
session. Registering a definition mid-run cannot add, remove, or repoint a name,
so the name a transcript shows resolves to the same generation on replay as it
did live. A model call naming something absent from the mapping is a terminal
`failed` tool call with reason `unknown_tool`; the name is never fuzzy-matched,
never lowercased into a neighbour, and never resolved against the registry
behind the mapping's back.

`M1`'s demonstration tools are the first case that exercises the separation.
Their `tool_id`, `tool_version`, and behaviour are retained exactly, and the
retained definitions carry conforming model-visible names because registration
requires one — `M1` had no name field to preserve. Since no reference profile
selects them, those names enter no session mapping and no provider request, so
the added field changes nothing a model or an executor sees.

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
| `register` with a `name` outside the declared character set | `{:error, :invalid_tool_name}` |
| `register` with a `name` another registered generation already uses | `:ok`; a duplicate name is refused where it matters, at active-set composition |
| `resolve(runtime, tool_id)` | highest registered semantic version at resolution time |
| `resolve(runtime, tool_id, tool_version)` | that exact generation, or `{:error, :unknown_tool_generation}` |
| `resolve` for an unregistered `tool_id` | `{:error, :unknown_tool}` |

There is no unregistration and no in-place replacement in `M2`. The active set
offered to the model is a bounded list of generations selected at session start
and committed with the session together with its name mapping, so a registration
that happens mid-run cannot change what the current run may call or what any of
its names mean.

Registration and active-set membership are therefore separate facts, and `M1`'s
demonstration tools are the first case that depends on the difference.
`loopex.demo.write` and `loopex.demo.wait_write` register at their exact `M1`
identities, versions, and behaviour so the inherited protected executor case
runs unchanged. No reference profile lists them, so no session offers them to a
model; only a test composition that names them explicitly puts them in an active
set. A selector asserts both halves: the executor case still starts the
credential-free operating-system tool and retains its receipt, and a session
built from the reference profile resolves neither identity, refusing a model
call that names one with `unknown_tool`.

Conformance for the runtime scoping is direct: start two runtimes in one VM with
disjoint tool sets and prove that each resolves only its own, that neither
observes the other's conflict, and that no registered name, application
environment key, or persistent term is created for a tool identity. That last
part is proved by inspection of the process registry and the application
environment rather than asserted.

### Resolution and recording

Per tool call, in this order:

1. Look the model-visible name from the model's call up in the run's committed
   name mapping. An unresolvable name is a terminal `failed` tool call with
   reason `unknown_tool`; it is never guessed and never dispatched.
2. Validate arguments against that generation's `parameter_schema`. A validation
   failure is a terminal `failed` tool call with a bounded diagnostic and no
   policy consultation.
3. Ask host policy, with the resolved generation, the validated arguments, the
   effect class, and the workspace lease reference. This step is unconditional:
   every executor-backed tool call reaches it, `read_only` calls included, and no
   effect class, tool identity, or argument shape routes around it.
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

### Artifact store port

```text
@callback put(handle :: term(), bytes :: binary(), metadata :: map()) ::
            {:ok, artifact_reference()} | {:error, term()}
@callback fetch(handle :: term(), artifact_reference()) ::
            {:ok, binary()} | {:error, term()}
@callback stat(handle :: term(), artifact_reference()) ::
            {:ok, artifact_reference()} | {:error, term()}
```

The handle is the explicit composition reference; it is edge-private placement
state and never enters a journal, a public event, or an executor job, which is
the same convention `Loopex.Store` and `Loopex.Executor` already use for an
in-VM composition reference. The error term is likewise an in-process return that
is categorized before anything durable records it. Neither is transported, which
is what separates them from a policy decision's context. The artifact reference
is bounded plain data and is the only thing here that does cross:

```text
digest        lowercase hexadecimal SHA-256 of the exact stored bytes
media_type    declared bounded type string
size          exact byte length
role          logical role, closed enumeration (tool_output today)
locator       opaque bounded retrieval reference, adapter-assigned
```

Contract rules, each individually asserted by the reusable suite so a later
adapter runs the same cases:

- `put` is content-addressed and idempotent. Storing identical bytes twice
  returns an equal reference and stores one object; storing different bytes can
  never return an equal digest, and the adapter compares bytes rather than
  trusting the digest it computed.
- `fetch` returns exactly the stored bytes or a typed error. A reference whose
  digest does not match the bytes read back is an integrity error, never a
  silent success.
- An unknown or collected reference fails as `{:error, :unknown_artifact}`. It
  is never an empty success, because a receipt that named it would otherwise
  read as a tool that produced nothing.
- Size ceilings are the adapter's and are declared. An over-ceiling `put` fails
  closed and the tool call reports a truthful failure rather than a truncated
  artifact.
- The `locator` is opaque to core. Core never parses it, joins it to a path, or
  reconstructs it, so a later adapter may use object storage without changing a
  recorded receipt's meaning.
- Pinning is explicit for the operation's retry and recovery window. Collection
  is a host and adapter duty and `M2` collects nothing automatically.

`M2` supplies two adapters. The filesystem adapter writes digest-addressed
immutable files under the resolved state root, using the same temporary-write
and rename discipline the local store already uses, and is what the reference
composition wires. The in-memory adapter exists for the suite and for core tests
that must not touch a real root. The trusted-local executor receives its
artifact reference at start, like its lease and ledger configuration; it does
not depend on a store application to obtain one, so no edge depends sideways on
another edge.

Spill is produced at the hand, exactly as §15.6 requires. The executor bounds
output, writes the overflow through its artifact reference, and returns the
bounded model-facing content together with the artifact reference in the
receipt. The coordinator commits the reference and never the bytes. When a hand
later runs in isolation or on another machine, it spills through its own adapter
and the receipt shape is unchanged.

### Host policy port

```text
@callback decide(request :: policy_request()) ::
            {:allow, policy_context() | nil}
            | {:deny, reason_category()}
            | {:defer, interaction_request()}
```

`policy_request` is bounded plain data: session and run identity, the resolved
generation triple, validated arguments, effect class, idempotency class, and the
workspace lease reference. It carries no pid, no credential, and no provider
value.

`policy_context` is bounded plain data too, and the boundary rule runs in both
directions because what an `allow` returns is transported into the grant, and a
grant is durable, digested, executor-facing data:

```text
decision_ref   opaque bounded binary the host assigns and only the host resolves,
               <= 256 bytes, never parsed, joined, or interpreted by Loopex
attributes     bounded map, binary keys, values binary | integer | boolean,
               <= 16 entries, <= 1 KiB canonical encoding
```

Both fields are optional and `nil` is a complete decision context. Nothing else
is admitted: no arbitrary Erlang term, no pid, port, reference, function, atom
from host input, nested structure, or unbounded binary. A host that needs to
carry richer state carries it behind `decision_ref` and resolves that reference
itself, which is what the opaque reference exists for. A returned context outside
this shape is a malformed return and resolves to `{:deny, :policy_unavailable}`
by the table below, so an over-permissive host cannot widen the boundary by
returning something bigger.

This is what ADR 0007's `optional bounded policy context` means concretely.
Loopex still interprets none of it — the host's user, role, and approval
semantics stay the host's — but "uninterpreted" was never a licence to transport
an arbitrary term across a durable boundary.

Consultation is universal. Every executor-backed tool call reaches `decide`,
including every `read_only` one, and the port has no exemption predicate. Two
reasons, and the second is the load-bearing one. A read is an effect: it crosses
the executor boundary under a workspace lease and lifts repository bytes into
model context and from there into a provider request, so which workspace and
which path a host permits is the host's decision by the ownership rule that also
covers writes. And an "effectful" predicate would be authority-bearing code
inside Loopex whose false branch is a dispatch path with no policy call on it. A
universal call site has no such branch, which is why the fail-closed table below
can be exhaustive: it enumerates policy answers, not tools.

`reason_category` is a closed enumeration — at minimum `policy_denied`,
`effect_class_not_permitted`, `workspace_not_permitted`,
`interaction_unsupported`, and `policy_unavailable` — so no free host text
reaches model context through a denial.

Fail-closed resolution is exhaustive:

| Observation | Resolution |
| --- | --- |
| `{:allow, context}` with a context inside the bounded shape, or `nil` | grant issued under ADR 0007 |
| `{:allow, context}` with a context outside the bounded shape | `{:deny, :policy_unavailable}`; nothing unbounded reaches a grant |
| `{:deny, category}` | durable denial, `denied` tool call, no dispatch |
| `{:defer, _}` in `M2` | `{:deny, :interaction_unsupported}` |
| Callback raises, exits, or times out | `{:deny, :policy_unavailable}` |
| Any other return shape | `{:deny, :policy_unavailable}` |
| No policy configured and any executor-backed tool active, `read_only` included | runtime start refused |

A denial commits before it is reported, so an aborted or crashed coordinator
cannot lose the fact that a call was refused, and the `denied` outcome is the
validated terminal fact the cancellation algebra must preserve.

`Loopex.Policy.AllowAll` ships in `loopex_reference_client`, the `:client`
application that is Loopex's reference host. The placement follows ownership, not
convenience: §6.4 assigns the authorization decision to the host, and deciding to
trust one's own workspace is exactly such a decision. The reference host makes
that decision for itself, names the module in its own configuration, and prints
the notice that says what it means.

Core is excluded because a permissive policy in core is a default in everything
but name. The trusted-local executor edge is excluded for the stronger reason:
an edge that shipped `AllowAll` would make the host's decision on behalf of every
embedder who composes that executor, including embedders who compose it precisely
because they intend to police it, and the permissive module would then be
inherited by the first isolated or remote hand that reuses the edge's
composition. An edge supplies a mechanism; it does not get to answer the host's
question.

The dependency direction is settled by the test fixtures rather than by
placement. `apps/loopex_executor_local/test/host_policy_test.exs` owns Outcome 7's
deny, fail-closed, and refusal-to-start selectors, and it defines its own policy
fixtures inside the test file: one refusing module returning `{:deny, category}`,
one permitting module returning `{:allow, nil}`, and the raising, sleeping, and
malformed-return modules the fail-closed cases need. It imports nothing from the
reference client. That is not a workaround for a placement problem; it is the
correct arrangement independently, because those selectors are testing the port's
behaviour under a decision, not testing the shipped permissive module. No
application depends on a `:client`, no edge depends sideways on another edge, and
no reader can conclude from this ADR that an edge imports a client.

The explicitness obligation splits along the same line. That a permissive policy
applies only when it is named in configuration, and that omitting the option
refuses runtime start rather than falling back to permission, is a property of
the runtime and is proved in the executor edge's selectors with its permissive
fixture — no shipped module required. That `Loopex.Policy.AllowAll` in
particular allows every decision and emits exactly one visible
permissive-authority notice is a property of that module and is proved in the
reference client's own test lane, where the module lives.

Two alternative homes were rejected against the minimalism budget. A seventh
application holding one module would add a project, a dependency record, and an
inventory row to give one module a home it already has. Core would make the
permissive choice invisible, which is the one property it must not have.

A selector proves that omitting the policy option refuses runtime start rather
than defaulting to it, and the dependency-budget check proves that no application
acquired a client, sideways edge, or external dependency in the course of this
arrangement.

### Cancellation

Admission first. `M2` admits an abort exactly where `M1` does: through
`Loopex.command/2` on an attachment held by the operating-system process that
runs the session. The reference command installs an interrupt handler that
submits that command with a fresh `command_id` when the operator presses Ctrl-C,
and a second Ctrl-C during cleanup re-presents the same command idempotently
rather than escalating. Nothing else can admit it: ADR 0008 permits one live
Runtime Control per Store identity and `runtime_id`, and the Store refuses a
second writer of session truth, so a separate `loopex cancel` process has no
path to the live coordinator and would have to either take ownership away from
a healthy owner or write session truth it does not own. Both are refused.
Cross-process cancellation therefore waits for the daemon milestone's socket
transport, controller policy, and stale-controller fencing.

The sequence then implements the vision's acknowledged cancellation protocol
without adding to it:

```text
abort admitted through the facade and committed (M1 admission, unchanged)
  -> coordinator stops scheduling new work for the run
  -> cooperative cancel to the in-flight model task or executor job
  -> declared bounded grace period elapses
  -> executor terminates the owned process tree by its captured kill identity
  -> cleanup confirmed
  -> operation: retain a validated completed / failed / denied fact
              | cancelled when cancellation caused termination
              | outcome_unknown when effect evidence is insufficient
  -> run: cancelled | outcome_unknown(reconciliation_ref)
```

The run outcome is derived from the owned operation outcomes, never assumed from
the fact that an abort was admitted:

| Every owned operation ended | Run outcome |
| --- | --- |
| Validated `completed`, `failed`, or `denied`, with no owned process tree left unconfirmed | `cancelled` |
| `cancelled` with confirmed cleanup | `cancelled` |
| At least one `outcome_unknown` | `outcome_unknown(reconciliation_ref)` referencing that operation and attempt |

Cleanup that is not confirmed is insufficient evidence, not a slower success. If
the grace period elapses, the owned tree is terminated by its captured kill
identity, and termination still cannot be confirmed, the operation ends
`outcome_unknown` and the run ends `outcome_unknown` with it. There is no path
that commits `cancelled` over an unproved effect or an unconfirmed process tree,
because a clean `cancelled` is precisely the report an operator would act on by
doing nothing.

The run's `outcome_unknown` carries the reconciliation reference of the first
unknown operation and enumerates the rest in its retained evidence, so an
operator reading only the run outcome — which is the outcome the reference
command prints — still learns that something needs reconciling. Both outcomes are
terminal and immutable: a later reconciliation appends a fact referencing the
original operation and attempt and never rewrites the emitted `run.finished`.

Ordering follows the committed journal. If a validated completion commits before
abort admission, the abort is acknowledged as already terminal. If abort
admission commits first, no new work is scheduled and any later evidence is
handled only through that operation kind's reconciliation rules. A late executor
receipt for a cancelled run is retained truthfully and is not projected into the
next model turn, because there is no next turn. A validated late `completed` or
`failed` leaves that operation truthful and still finishes the run `cancelled`;
only an unprovable one moves the run to `outcome_unknown`. `outcome_unknown`
reaches ADR 0007's reconciliation path unchanged, including its
solicited-response and fencing requirements.

The grace period is a declared session configuration value with a default and is
reported in the terminal outcome's evidence, so an operator can distinguish a
clean cooperative stop, a forced kill that was confirmed, and a termination that
could not be confirmed at all.

### Evidence

Claim-proportional evidence for this decision:

- registry conflict, idempotent re-registration, additive versioning, reserved
  namespace, invalid name, and unknown-generation resolution, each with its exact
  reason;
- name-mapping evidence: a session whose active set claims one name twice refuses
  to start with `duplicate_tool_name` naming both generations, a provider request
  built from the mapping lists each name exactly once, a model call resolves by
  name to the exact recorded generation, an unmapped name is a terminal
  `unknown_tool` that dispatches nothing, and a registration performed mid-run
  changes neither the mapping nor what a name resolves to;
- two runtimes in one VM with disjoint tool sets, plus inspection proving no
  VM-global name or application-environment key was created;
- a recorded generation that survives a restart and is used for validation and
  dispatch after recovery, with a registry changed in between;
- one shared behaviour suite run against all four bootstrap tools, including
  refusal cases for escape by absolute path, escape by relative traversal,
  escape by symlinked component, zero-match and multi-match edits, mode misuse
  in `bash`, ceiling-crossing output with artifact spill, and descendant process
  cleanup;
- policy conformance covering allow, deny, defer-in-`M2`, timeout, crash,
  malformed return, and an out-of-shape `allow` context, each asserting the exact
  resolution above and asserting that no job was dispatched for every non-allow
  case;
- a policy decision taken for a `read_only` call as well as for each effectful
  class, with a denied `read` proving no job was dispatched and no bytes reached
  model context, and a call-site assertion that the number of policy
  consultations equals the number of resolved tool calls for a run mixing all
  four effect classes;
- a `policy_context` boundary case: an `allow` returning the maximum admitted
  context is transported into the grant and retained unchanged, and one returning
  a pid, a function, a nested structure, or an over-ceiling binary denies with
  `policy_unavailable` and reaches no grant;
- artifact-store conformance covering content-addressed idempotent `put`,
  byte-exact `fetch`, digest mismatch as an integrity error, unknown reference,
  over-ceiling refusal, and an opaque locator core never parses, run against
  both the filesystem and in-memory adapters;
- one ceiling-crossing `bash` invocation whose bounded model-facing content
  carries a truncation marker and an artifact reference, whose spilled bytes are
  byte-identical to the untruncated output, and whose receipt stays
  reconstructable after a restart;
- `M1`'s locked executor case passing unchanged at its exact identity, beside a
  reference-profile session that refuses a model call naming either
  demonstration tool with `unknown_tool`;
- refusal to start a runtime with any executor-backed tool active and no
  configured policy, including a `read_only`-only active set; a dependency-budget
  run proving no application acquired a client, sideways edge, or external
  dependency; and reference-client selectors proving `AllowAll` applies only when
  named explicitly and emits exactly one permissive-authority notice;
- abort during a model call and abort during an executor effect, each admitted
  through the facade, each proving owned work stopped, cleanup confirmed, the
  terminal fact truthful, and no late result projected into model context;
- an abort whose owned effect cannot be proved: the operation ends
  `outcome_unknown`, the run ends `outcome_unknown` with a reconciliation
  reference rather than `cancelled`, the operator-facing output says so, and the
  case is driven by injected unprovability rather than by timing luck;
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

**`tool_id`-only resolution, or a name precedence rule.** Resolving by
`tool_id` needs no mapping and no conflict rule, and a precedence rule needs the
mapping but never refuses. `tool_id`-only fails first: a dot-segmented identity
is not a portable provider tool name, so an adapter would have to invent a
name-to-identity translation anyway, and it would do so privately, per adapter,
with no journaled record of what the model actually saw. A precedence rule fails
differently and worse. It resolves the ambiguity by a rule nobody reads — highest
version, or selection order — so the code behind a familiar name changes when a
profile gains a claimant, the transcript still shows one word, and the
before-and-after are indistinguishable in evidence. Refusing at composition costs
one error message and makes the collision impossible to miss.

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
proof — and a client flow to answer it. That is a milestone, and the first
client flow able to answer it is the headless session protocol's interaction
request and response round trip. The fail-closed mapping is what makes
the deferral safe: an `M2` policy that returns `defer` denies, so no code path
treats an unimplemented decision as permission.

**Configuration allowlist instead of a port.** A map of tool identity to boolean
would let a host say no today. It cannot express the per-call facts that decide
real cases — this path, this command, this effect class, this workspace — so
every real host would immediately need an escape hatch, and the escape hatch is
the port. It also places the decision inside Loopex, contradicting the ownership
map's assignment of authorization to the host.

**A read-only exemption from policy.** Skipping `decide` for `read_only` saves a
per-call decision on the most frequent tool in a coding session, and reads feel
like the safe case. Two objections. The behavioural one: a read under a workspace
lease is an executor effect that moves repository bytes into model context and
therefore into a provider request, and whether this host permits this workspace
and this path is the same host question a write asks. The structural one decides
it: the exemption requires a predicate, the predicate is authority-bearing code
inside Loopex, and its false branch is a reachable dispatch path with no policy
consultation on it. Every subsequent tool then arrives as an argument about which
side of the predicate it belongs on, and the first one argued wrong is unpoliced
in production. Universal consultation removes the branch instead of auditing it.

**An uninterpreted host term in the grant.** The maximally flexible `allow`
returns `term()` and Loopex promises not to look. It is rejected on the plain
boundary data rule rather than weighed: the value is transported into a grant
that is durable, canonicalized into a digest, retained in a receipt, and
validated by an executor. A pid or a function there is meaningless after a
restart, an unbounded structure defeats the boundedness every other field
maintains, and an atom from host input is a well-known table-exhaustion hazard.
The opaque `decision_ref` gives a host precisely the indirection the term was
wanted for, at the cost of the host resolving its own reference — which is where
that resolution belonged.

**`AllowAll` in the trusted-local executor edge.** It puts the permissive module
beside the executor that already carries the user's operating-system authority,
and it keeps the policy selectors and the permissive module in one application.
It is not recommended. Placement of a policy is an ownership statement: an edge
that ships a permissive policy has answered the host's question for every
embedder that composes it, and a future isolated or remote hand reusing that
composition inherits an `AllowAll` nobody chose for it. The dependency argument
that made this placement look forced does not survive inspection either. The
executor edge's selectors need policy fixtures, not the shipped module, and
in-file fixtures are both smaller and a better test: they exercise the port under
a decision instead of asserting the reference host's default twice.

**Spill into the journal or straight onto the store's files.** Mechanically
trivial: the executor already writes a receipt file and the coordinator already
commits records. The cost lands in two places. Session size stops being
proportional to bounded model-facing content and starts being proportional to
raw command output, which defeats the ceiling that made the durable conversation
finite in the first place; and the write path assumes the producer of the bytes
can reach the brain's storage, which is exactly the assumption the executor
protocol exists to avoid. Retrofitting the seam later would change the meaning
of every retained receipt that names a spill.

**An artifact helper module in core rather than a port.** Two functions and no
behaviour would carry `M2` end to end. The suite is what distinguishes the two
options: §23.2 already requires artifact-store adapters to run a reusable
conformance suite, and §12.6 assigns location, encryption, access control,
retention, and collection to the adapter and host. A core helper would have to
grow those duties into core or refuse them, and the second implementation — an
object-store or hosted adapter — is a scheduled consequence of the daemon and
hosted work rather than a speculation.

**Deleting or renaming the demonstration tools.** `M1`'s locked selector for
`apps/loopex_executor_local/test/executor_test.exs` protects the case that one
credential-free operating-system tool writes the expected workspace bytes and
its receipt is retained, and the executor implements exactly
`loopex.demo.write` and `loopex.demo.wait_write`. Deleting them fails that
locked case; renaming them fails it and additionally asserts a continuity of
meaning that does not exist. Retention plus profile exclusion satisfies both
constraints and costs one rule that a later extension milestone needs anyway.

**A second process that admits an abort by writing the Store.** The only way to
make a separate `loopex cancel` work in `M2` would be to let a process that is
not the session owner write session truth, or to take ownership from a healthy
owner in order to stop it. The first contradicts the single serial writer; the
second is a succession, which is a heavier and more dangerous operation than the
cancellation it would implement, and ADR 0008 refuses two live Controls over one
Store identity and `runtime_id` regardless. The in-process facade admission is
not a compromise; it is the only correct admission path this milestone has.

**A single `cancelled` run outcome.** Collapsing the run outcome to `cancelled`
removes a case from every renderer and gives an operator one answer to one
gesture. It is not recommended, and the reason is not symmetry with the tool
outcome — it is that the run outcome is the one an operator reads. A run reported
`cancelled` while its owned effect stayed unprovable tells the operator the
system is at rest, which is the single most expensive wrong statement this
milestone could make: the reconciliation the tool outcome demands then has no
visible trigger. Keeping `outcome_unknown` at the run level costs one branch in
the reference command's output and one more case per surface, and it is what the
vision's algebra already specifies.

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
  and, in the worst case, a run that finishes `outcome_unknown` and names a
  reconciliation reference rather than a comfortable false `cancelled`. Every
  surface that renders a run outcome carries that second ending, and no
  documentation may promise that Ctrl-C guarantees a clean stop.
- Model-visible names become committed session state. The name mapping is
  journaled with the active set, replay resolves the exact name the run used, and
  a duplicate name refuses session start. Later profile and extension work
  inherits that refusal: two contributors claiming `search` collide visibly at
  composition instead of resolving by a precedence rule nobody reads.
- Policy is consulted on every executor-backed call, so a `read`-heavy session
  pays one host decision per read and every host implementation must answer reads
  as well as writes. The removed alternative — an exemption predicate with an
  unpoliced false branch — is what that cost buys.
- The permissive policy lives with the reference host. An embedder who composes
  the trusted-local executor gets a mechanism and no policy, and must name one,
  which is the intended friction. The reference client keeps one module and one
  notice that its own tests own.
- Cancellation stays inside the process that owns the session. An operator with
  two terminals cannot stop a run from the second one, and a command surface
  that offers such a subcommand would be offering something the runtime cannot
  do. That limit is visible in the reference command and disappears with the
  daemon milestone rather than with a workaround.
- Composition grows from three references to five. Every embedder, every test
  composition, and the shipped composition module supply a policy and an
  artifact store, and two more conformance suites run in every lane. The
  narrowness of both ports is the justification, so neither may absorb a second
  responsibility without a successor decision.
- Artifact bytes become state with a lifetime nobody collects in `M2`. A long
  session that runs a noisy test suite accumulates digest-addressed files under
  the state root until an operator removes them, and retention and collection
  stay host duties the reference composition does not perform.

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
- Without the artifact port, the bounded-output rule either loses the bytes it
  claims to keep or pushes a test log into the private journal, and the first
  isolated hand would find that its spill target is the brain's filesystem.

<a id="technical-adr-0009-compatibility"></a>
## Format, Migration, and Rollback Mechanics

Concept: [Compatibility, migration, and rollback](0009-tool-executor-and-grant-contracts.md#concept-adr-0009-compatibility).

The durable format gains the active-set record committed at session start
together with its model-visible name mapping, the per-call generation triple on
each tool-operation intent, the durable denial record and its bounded policy
context, the artifact reference carried on a tool result and its receipt, and the
cancellation evidence retained with a terminal operation and run outcome,
including the reconciliation reference an unknown run outcome carries. All are bounded plain
data in the session mutation domain and none crosses into a public plane except
through the existing bounded tool-call events.

There is no installed base and no published package, and `M2` tags no version:
`VERSION` stays `0.0.0` and the first version number belongs to the headless
session-protocol milestone. The tool definition shape, the policy callback, the
reason categories, the artifact reference, and the active-set record are all
experimental and freeze nothing, as are the name mapping and the bounded
`policy_context` shape. `M1` journals are neither read nor migrated and
`M1`-owned test roots are discarded rather than upgraded; `M1`'s two
demonstration tool definitions are retained unchanged, outside every active
profile, so that its locked executor case keeps passing.

Rollback before closure removes the registry, the four bootstrap tools, the
policy port, the artifact port, the denial record, and the cancellation path
together, and returns the runtime to the `M1` single-tool option. Partial
rollback is not available: the grant path depends on both resolution and policy,
cancellation depends on the executor capturing kill identity at accept time, and
bounded output depends on a spill target. Once a version is published, changing
a built-in's `tool_id`, model-visible name, effect class, or parameter schema is
a new `tool_version` under the additive registration rule; the old generation
stays resolvable for any journal that names it. Removing a reason category,
widening the schema subset, widening the `policy_context` shape, changing the
artifact reference fields, changing how a model-visible name resolves, or making
`defer` executable each require a successor decision, because each changes what a
recorded decision, name, or receipt meant.
