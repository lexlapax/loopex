# Compatibility Surfaces

<a id="concept"></a>
## Concept

Every surface M2 touches is unstable. None is labelled, frozen, versioned for
consumers, or given a compatibility promise, and none is owed a deprecation
window or a migration note. `VERSION` is `0.0.0`, nothing is tagged, and nothing
is published, so the vision's package surface — released names, their contents,
and the constraints they declare — stays inert because it has never been
created.

That is a deliberate position, not an omission. The
[compatibility contract](../vision.md#concept-vision-compatibility) freezes a
surface only when its own consumers, schemas, vectors, migration, rollback, and
operational evidence justify the claim. No surface in this milestone has those,
so labelling one stable would be a promise with nothing behind it.

For an embedder this means: pin an exact revision, expect any surface named
below to change without notice, and read the changelog for the milestone you
move to rather than a version constraint. Treat the whole umbrella as one
moving target — a change to the private journal, the executor protocol, or the
tool record can reach you through the facade you call.

One consequence is concrete and worth stating on its own: **a session data root
written by an M1-era revision is not readable by M2.** M2 adds new durable
record kinds for conversation turns, tool definition generations, denials,
steers, follow-ups, and cancellations. There is no migration, and none is owed,
because M1 accepted no installed-store compatibility contract and M2 accepts
none either. Start M2 with a fresh state root.

Internal process topology, process messages, supervision structure, and private
structs are not a public surface at all, at any point, and are not listed below.

The scoped statement of this position for the milestone is
[M2's compatibility section](../plans/M2-technical.md#technical-plan-compatibility).
Operator-facing consequences:
[Coding sessions](../operator/coding-sessions.md#concept) and
[Tools and policy](../operator/tools-and-policy.md#concept).

<a id="technical-depth"></a>
## Technical depth

### The Surfaces M2 Touches

Each row names what an embedder or operator can reach, and the vision surface it
belongs to under
[separately versioned surfaces](../vision-technical.md#technical-vision-compatibility).

| Surface | Reached through | Vision surface | State |
| --- | --- | --- | --- |
| Embedded facade | `Loopex` | 5, embedded Elixir API | Unstable |
| Store port | `Loopex.Store` behaviour and handle | 1, private journal and store schema | Unstable |
| Model port | `Loopex.Model` behaviour, request and reply shapes, delta contract | 2, public protocol semantics | Unstable |
| Executor port | `Loopex.Executor` behaviour, job, grant, receipt, `cancel/2` | 3, executor protocol | Unstable |
| Policy port | `Loopex.Policy` behaviour, request, context, refusal categories | 2, public protocol semantics | Unstable |
| Artifact-store port | `Loopex.ArtifactStore` behaviour and `artifact_reference` | 6, artifact formats | Unstable |
| Durable record shapes | committed record kinds, replayed by `Loopex.Runtime.SessionState` | 1, private journal and store schema | Unstable, and changed in M2 |
| Public event shapes | `Loopex.attach/3`, `Loopex.next_event/1` | 2, public protocol | Unstable |
| Tool definition contract | `LoopexProtocol.ToolDefinition`, `LoopexProtocol.Canonical` | 2 and 3 | Unstable, new in M2 |
| Reference composition | `LoopexComposition.start/1` and `artifacts/1` | 5, embedded Elixir API | Unstable, new in M2 |
| Operator command | the `loopex` escript and its subcommands and flags | not yet a listed surface | Unstable, new in M2 |

Surface 4, the extension manifest and lifecycle API, does not exist yet. Surface
7, released package names and their contents, is inert: no package is published,
so nothing has welded two surfaces together by shipping them in one artifact.

### What Each Surface Currently Consists Of

**Embedded facade.** `Loopex.start_link/1`, `stop/1`, `create_session/3`,
`resume_session/3`, `resume_known_session/4`, `attach/3`, `command/2`,
`next_event/1`, `snapshot/1`, `attachment_status/1`, `progress/2`,
`diagnostic/2`, `session_status/2`, `reconciliation_query/1`, `reconcile/2`,
`state_root/0`, `runtime_placement_id/1`, `track_session/3`, `list_sessions/1`,
and `version/0`. The runtime start options are part of this surface, including
`:tools`, `:active_tools`, `:policy`, `:bounds`, `:sampling`, `:progress_to`,
`:diagnostics_to`, and `:cleanup_grace_ms`.

**Ports.** Core declares exactly five behaviours: `Loopex.Store`,
`Loopex.Model`, `Loopex.Executor`, `Loopex.Policy`, and
`Loopex.ArtifactStore`. M1 declared the first three; M2 adds the last two, and
widens `Loopex.Executor` with the required `cancel/2` callback recorded in
[M2 recorded limitations](../evidence/M2-recorded-limitations.md). It returns
`{:ok, :cleaned}`, `{:ok, :unconfirmed}`, or `{:error, term()}`. The facade maps
the latter two, a malformed or failed call, and the defensive case of a legacy
module missing the required callback to unconfirmed cleanup. An implementation
of any port is written against bytes that may change in the next milestone.

The shipped local executor gains two start options, `cleanup_grace_ms` and
`process_probe`, each readable back from the running executor and recorded on
every receipt it retains. `process_probe` is the local executor's own
configuration and defaults to `/bin/ps`. `cleanup_grace_ms` is not: ADR 0009
makes the cleanup period a declared *session* configuration value, so the
default lives on the port as `Loopex.Executor.default_cleanup_grace_ms/0` and the
session declares it. `LoopexComposition.start/1` hands one number to both, which
is what stops a run's terminal naming a period its cleanup did not run under. An
embedder that passes neither behaves exactly as before.

`Loopex.Executor`'s job request gains one declared budget,
`resource_budgets["max_wall_time_ms"]`, beside the output ceiling already there.
`resource_budgets` is an open plain map, so this is additive: an executor that
ignores the key behaves as before, and the shipped local executor bounds a job by
the smallest of the run's instant, that budget, and the budget its own copy of
the definition declares. The key is covered by the job's canonical digest like
every other semantic field, so a job built by an M2 coordinator and one built by
hand without it are different jobs.

**An abort's acceptance is an admission, not an ending.** `Loopex.command/2`
returns `{:accepted, command_id}` once the abort commits durably; ADR 0009 then
orders the cleanup, then the run's terminal. The run is still active between the
two, so a prompt submitted there is queued as a follow-up on that run rather
than starting a new one, and a caller that needs the run over waits for its
`run.finished` event. The previous shape committed the admission and the ending
as one record after the cleanup, which is why no caller had to think about the
gap — and is also why a host that died inside the cleanup left no record that
anyone had asked to stop.

`Loopex.Executor` gains no second callback, but the *meaning* of one of its
return values changed and an existing implementation is affected without
recompiling. An executor that refused a job before its effect started says so by
returning `{:error, {:refused_before_effect, reason}}`; the runtime commits that
as an ordinary terminal `failed` carrying `reason`. Every other `{:error, _}` is
read as unproven and ends the run `outcome_unknown` with a reconciliation
reference. The runtime previously recognised a list of error *names* copied from
the shipped local executor and applied to every implementation, which meant a
conforming executor that lost its lease halfway through a write and returned
`{:error, :workspace_lease_lost}` had that effect committed as `failed` and the
loop carried on past it. Failing closed is the correct default and it is a real
behaviour change: an executor that adopts nothing keeps compiling, stays
conforming, and sees errors that used to end a call `failed` now end the run
`outcome_unknown`.

**Progress plane.** Every item of a stream domain, including its closing item, is
now emitted by one process per open domain rather than by the producer's callback
and the coordinator between them. Nothing about the items changes — same shapes,
same labels, same sequences — but a consumer can now rely on the rule ADR 0011
already stated and this runtime only approximated: no item of a domain appears
after that domain's closure.

**Canonical model deltas.** `Loopex.Model.valid_delta?/1` now requires a delta to
carry *exactly* the fields `Loopex.Model.delta_fields/1` declares for its kind.
Carrying an undeclared name was already refused; omitting a declared one now is
too, so an adapter that emitted `%{kind: :text_delta, text: "x"}` without a
`content_index` had that item published and counted before and has it dropped
now. The payload ceiling is also total: any field whose size the named
measurements do not otherwise know is measured by encoding it, so an unbounded
integer no longer measures as nothing. Both are behaviour changes for an adapter
that compiles unchanged, and the shipped adapter already emitted complete deltas.

**Durable records.** The committed record kinds are `session_genesis`,
`owner_advanced`, `command_admitted`, `model_request_committed`,
`model_result_committed`, `model_attempt_abandoned`,
`effect_intent_committed`, `executor_receipt_committed`,
`executor_progress_refused`, `tool_result_committed`,
`outcome_unknown_committed`, and `run_terminal_committed`. Their payloads carry
the M2 loop's new content — projected conversation elements, staged request
bytes and their `staged_request_digest`, generation triples, declared bounds and
charged tokens, denials, and terminal detail. This is the surface an M1-era data
root fails on.

**Public events.** The event kinds are `user.message_appended`, `run.started`,
`assistant.message_appended`, `tool.started`, `tool.finished`, `run.finished`,
`steer.resolved`, and `follow_up.resolved`. `tool.started` now carries `tool_id`
and `tool_version` and `tool.finished` carries `tool_id` and the outcome, so a
terminal can name the tool rather than only an opaque call identifier. A call
whose name resolved to no active generation carries no tool identity, because
publishing the model-supplied string would read as a name the runtime accepted.
Progress items and diagnostics are
transient and are not this surface: they are not durable truth and carry no
compatibility expectation at all.

**Tool definition contract.** The nine required fields, the evaluable schema
subset, the generation triple, the reserved `loopex.` namespace, and the
canonical encoding `loopex.canonical.v1` with the record tag
`loopex.tool_definition.v1`. Widening the schema subset or the budget set is
additive and does not disturb a retained generation, because a definition that
did not use the wider form encodes exactly as it did before; anything else is a
breaking change to every retained digest. See
[Agent loop and tools](agent-loop-and-tools.md#technical-depth).

**Reference composition.** `LoopexComposition.start/1` requires `:runtime_id`,
`:state_root`, `:workspace`, and `:policy`, and accepts `:progress_to`,
`:diagnostics_to`, and `:cleanup_grace_ms`; it passes `:project_manifest` and
`:project_decision` through to the runtime, and hands `:cleanup_grace_ms` to the
session and the executor together so a run's ending cannot report a period its
cleanup did not run under. `:process_probe` reaches the executor alone, which is
where that option belongs. It names four concrete implementations, so an embedder that
depends on it transitively acquires the reference adapters and their external
dependency whether or not every one is used. An embedder who wants a different
Store, Model, Executor, or ArtifactStore composes the ports and the `Loopex`
facade directly instead. See
[Runtime and embedding](runtime-and-embedding.md#technical-depth).

**Operator command.** `loopex run`, `sessions`, `resume`, `cancel`, and
`artifact`, with the flags `--policy`, `--state-root`, `--workspace`,
`--steer`, `--follow-up`, and `--cleanup-grace-ms`. An unrecognised flag is refused rather than
ignored, which means adding a flag is observable and removing one is breaking.
`loopex artifact` reads objects through the `Loopex.ArtifactStore` port, so the
subcommand follows whatever artifact store a composition supplies rather than
naming the local one. `--policy` accepts `allow-all` and `shell-allowlist`;
the set of accepted names is part of the surface, so adding one is observable
and removing one is breaking.

### What an Embedder Should Do About It

- Pin an exact revision of this repository. There is no version constraint that
  expresses "the M2 loop", because no version has been published.
- Do not persist anything that depends on a durable record shape outside the
  Store, and do not read the store's files with your own code.
- Treat `artifact_reference.locator` as opaque. Core never parses, joins, or
  reconstructs it, and an adapter is free to change what it means.
- Treat `stream_domain_id` as an opaque comparison key of 32 hexadecimal
  characters; its derivation may change behind that stability.
- Expect the absence of a stream closure. It is an emission obligation, never a
  delivery guarantee, so a consumer falls back to the durable record rather than
  inferring abandonment.
- Handle `{:defer, _}` never being honoured. A host policy may return it; M2
  resolves it to `{:deny, :interaction_unsupported}`, and the shape exists so
  that hosts need not change when interaction lands.
- Start on a fresh state root when moving from an M1-era revision.

### What Would Have To Exist Before Any Freeze

Nothing here becomes a release candidate by accumulating usage. Under the
[compatibility contract](../vision.md#concept-vision-compatibility) and its
[technical rules](../vision-technical.md#technical-vision-compatibility), a
surface needs schemas, conformance vectors, independent consumers, and
upgrade and rollback evidence appropriate to what it claims, and the public
protocol specifically waits until embedded, RPC, daemon, host, and extension
callers have exercised its semantics. Executor-protocol stability additionally
waits on isolated and remote evidence, not only the trusted-local implementation
this milestone ships. Deciding what a published package would contain is itself
a compatibility decision, because a consumer pins the package rather than the
surface inside it.

Until a milestone does that work and records it, the answer to "is this stable
yet" is no, for all of the above.
