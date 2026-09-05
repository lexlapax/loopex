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
| Executor port | `Loopex.Executor` behaviour, job, grant, receipt, `cancel/2`, optional `retained_receipt/2` | 3, executor protocol | Unstable |
| Policy port | `Loopex.Policy` behaviour, request, context, refusal categories | 2, public protocol semantics | Unstable |
| Artifact-store port | `Loopex.ArtifactStore` object/use behaviour and eight-member `artifact_reference` | 6, artifact formats | Unstable |
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
`resume_session/3`, `resume_known_session/4`, `attach/2` and `attach/3`,
`command/2`,
`next_event/1`, `snapshot/1`, `attachment_status/1`, `progress/2`,
`diagnostic/2`, `session_status/2`, `reconciliation_query/1`, `reconcile/2`,
`prepare_resume_session/3`, `prepare_resume_known_session/4`,
`activate_resume/1`, `abandon_resume/1`, `transfer_resume/2`, `state_root/0`,
`runtime_placement_id/1`, `track_session/3`, `list_sessions/1`, and `version/0`.
Prepared resume entries return an opaque one-use activation capability; neither
preparation nor handler installation schedules recovered work. `activate_resume/1`
and `abandon_resume/1` wait for the coordinator's answer rather than expiring on
a bound. The message carrying either call is not withdrawn when its caller stops
waiting, so a bounded call that expired would report the session unavailable
while the coordinator went on to spend the very activation the caller was told it
had not got. Neither call proposes a Store mutation, so waiting commits nothing,
and a coordinator that has died still refuses, because its exit is the answer.
The runtime
start options are part of this surface, including
`:tools`, `:active_tools`, `:policy`, `:bounds`, `:sampling`, `:progress_to`,
`:diagnostics_to`, `:cleanup_grace_ms`, and the required positive
`:context_token_budget`. Direct Runtime callers choose that context value;
Runtime supplies no default.

**Ports.** Core declares exactly five behaviours: `Loopex.Store`,
`Loopex.Model`, `Loopex.Executor`, `Loopex.Policy`, and
`Loopex.ArtifactStore`. M1 declared the first three; M2 adds the last two, and
widens `Loopex.Executor` with the required `cancel/2` callback accepted in
[ADR 0012](../adr/0012-executor-cancellation-capability.md#concept). This is a
source-breaking change for a previous module that declares
`@behaviour Loopex.Executor` but does not implement `cancel/2`: it must add the
callback before it is conformant. The callback returns `{:ok, :cleaned}`,
`{:ok, :unconfirmed}`, or `{:error, term()}`. The facade defensively maps the
latter two, a malformed or failed call, and a legacy module missing the required
callback to unconfirmed cleanup. That fallback makes mixed-version failure safe;
it does not restore conformance to an implementation that omits the callback.
The port also declares an optional `retained_receipt/2`, which reads the terminal receipt
an executor retained for one job: `{:ok, receipt}`, `:absent`, or
`{:error, term()}`, with `{:error, :effect_in_flight}` reserved for a job the
executor still holds; the shipped local executor also answers
`{:error, :effect_unresolved}` for an admitted effect no live instance is
settling and `{:error, :effect_settling}` for a receipt whose open entry still
stands, and a receipt is final only once its entry is gone. The session
coordinator consults it once when a prepared resume is activated over a
dispatched effect, ending the run `outcome_unknown` on absence, an unresolved
entry, or a settling one; `Loopex.Executor.retained_receipt/3` bounds
the call and reports an absent callback, a raise, a malformed answer, or the
bound elapsing as distinct errors that leave reconciliation host-driven. Omitting
it is conformant. An implementation of any port is written against bytes that
may change in the next milestone.

The shipped local executor's `process_probe` start option is edge configuration,
defaults to `/bin/ps`, and is recorded on receipts that use it. The cleanup
period is different: the session commits it, every job and terminal carries it,
and `Loopex.Executor.cancellation_bounds/1` derives each production observation
window from it. `Loopex.Executor.cancel/4` applies that configured observation
around required callback `cancel/2`; retained `cancel/3` is a defensive legacy
entry and production coordination never selects it. Local's
`prepare_placement/3` prepares the durable ledger generation under the same
committed value before effect authority exists. These additions are source and
behaviour changes to direct integrations even though every surface remains
unreleased.

**Artifact object and use identity.** The adapter callbacks are `put/3`,
`fetch/2`, `stat/2`, and `describe/2`. Core owns the caller-facing
`Loopex.ArtifactStore` facade, computes and validates the object and immutable
use identities, and exposes locator-only `retrieve/2`; runtime, command, and
embedders do not call a concrete adapter. The compact reference has eight
members: object digest, size, and locator; media type and role; and use
canonicalization version, digest, and digest-derived locator. The exact five
provenance labels remain private behind `describe/2`. This breaks every caller
or adapter written against M2's earlier five-member reference or three-callback
shape; no compatibility decoder reconstructs missing use truth.

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
after that domain's closure. ADR 0014 narrows the producer-liveness promise, not
the consumer input algebra: abrupt owner death and recognized executor owner
loss without a retained terminal fact may end the process-local plane without a
closure, while a retained terminal fact may still close its originating domain
truthfully after handoff. Consumers already had to tolerate a missing closure
because delivery is transient; they keep the same durable fallback and infer no
abandonment.

**Canonical model deltas.** `Loopex.Model.valid_delta?/1` now requires a delta to
carry *exactly* the fields `Loopex.Model.delta_fields/1` declares for its kind.
Carrying an undeclared name was already refused; omitting a declared one now is
too, so an adapter that emitted `%{kind: :text_delta, text: "x"}` without a
`content_index` had that item published and counted before and has it dropped
now. The payload ceiling is also total: any field whose size the named
measurements do not otherwise know is measured by encoding it, so an unbounded
integer no longer measures as nothing. Both are behaviour changes for an adapter
that compiles unchanged, and the shipped adapter already emitted complete deltas.

A reply's usage map is also closed to `input_tokens` and `output_tokens`. An
adapter that reports a third key — a cache count, a reasoning count, a provider's
own total — now settles the attempt as `unreadable_model_answer` instead of
having the extra number silently dropped, because a usage record Core cannot
account for in full is one it must not charge from. Omitting either key stays
legal and normalizes as unreported; a present but unreadable value is classified
rather than refused. Widening that key set is the change a later milestone makes
deliberately, and it is why the closure exists rather than a lenient filter.

**Store port.** An append failure gains one pair of reasons and one changed
consequence. The local Store holds the log *file* rather than its path: it
records the file's device and inode at start-up and re-reads the path once its
append handle is held, because opening in append mode creates a missing file and
a check made only before the open would let a removal be answered with a new,
empty, history-free log at the same name. A log removed or replaced underneath a
live Store is `{:log_unavailable, :enoent}` or `{:log_unavailable, :replaced}`,
commit-ambiguous exactly as any other append failure is: the caller receives
`{:commit_unknown, tx_id}` and must re-present that exact transaction, and the
Store process terminates for recovery rather than continuing against a file it
cannot vouch for. An implementation that never checked its own file identity
keeps compiling and stays conformant; a caller that read an append error as a
non-commit was already wrong and now fails visibly instead of quietly.

Item admission has one refusal taxonomy, and the reason atoms moved. Building a
transaction, preflighting through `Loopex.Store.normalize_and_measure_item/2`,
and validating a transaction run the same normalizer and the same measurement,
so the same bytes get the same answer whichever way a caller reaches the
boundary. An item that is not bounded plain data is `:invalid_item` for a
private record and `:invalid_event` for a public event, replacing
`:not_plain_data`, `:not_plain_event_data`, `:invalid_record`, and
`:reserved_event_field`. A depth or cardinality breach is
`{:item_structure_exceeded, dimension, observed, limit}` and an oversized item
is `{:item_too_large, observed, limit}`; both now survive a list's own refusal
rather than collapsing into `:invalid_records` or `:invalid_events`, which is
what lets a preflight and a commit agree about one item. A caller that matched
on the old atoms must change; one that reported the reason as opaque text does
not. The list-level `:invalid_records` and `:invalid_events` remain for an
ordinary malformed member, because which member was malformed tells a caller
nothing it can act on.

**Durable records.** M2's session schema includes `session_genesis_v2`,
`owner_advanced`, `prompt_admitted_v2`, the other input-command admissions and
`command_admission_refused_v1`, `model_request_committed`,
`model_attempt_opened_v1`, `model_termination_admitted_v1`,
`model_attempt_settled_v1`, `context_admission_refused_v1`,
`deadline_staging_failed_v1`, `effect_intent_committed`,
`executor_receipt_committed`, `tool_result_committed`,
`outcome_unknown_committed`, and `run_terminal_committed`. The model-attempt
records replace the earlier `model_result_committed`,
`model_attempt_evidence_retained`, and `model_attempt_abandoned` vocabulary:
opening identifies one permitted attempt, settlement atomically carries bounded
result, accounting, conversation disposition, and next action, and only exact
pretransport refusal permits attempt two. A settlement naming a retry at the
attempt limit, and one whose reply carries a termination without being
evidence-only, are refused as invalid history rather than applied, so no owner
installs permission for an attempt that can never open and no answer is retained
that the run has no record of receiving. The payloads also carry projected
conversation elements, staged request bytes and digest, tool generations,
context and Store-admission observations, declared bounds, cleanup truth,
denials, and terminal detail. The Local executor's generation, admission, open,
refusal, and receipt ledgers and ArtifactStore object/use records are separate
kind-owned durability domains. This is the surface an M1-era data root fails on.

**Public events.** The event kinds are `user.message_appended`, `run.started`,
`assistant.message_appended`, `tool.started`, `tool.finished`, `run.finished`,
`steer.resolved`, and `follow_up.resolved`. `tool.started` now carries `tool_id`
and `tool_version` and `tool.finished` carries `tool_id` and the outcome, so a
terminal can name the tool rather than only an opaque call identifier. A call
whose name resolved to no active generation carries no tool identity, because
publishing the model-supplied string would read as a name the runtime accepted.
A `run.finished` that ends `failed` carries a `failure` projection only where a
context refusal was actually admitted and a `reason` only where one exists, so a
consumer reads one or the other and never a placeholder for both.

Delivery is now fenced by resolution as well as by commit: an attachment is
handed rows only up to the position the runtime has acknowledged as resolved, so
a durably linearized row whose owner still holds an unresolved transaction is
invisible until re-presentation settles it. The fence binds both paths to the
outbox. `Loopex.attach/3`'s own snapshot scan stops at that same acknowledged
position rather than at the durable tail, so an attachment's anchor never
reports run state derived from a row no consumer may yet read and never sets its
cursor past rows the event plane still owes it. A session this runtime does not
own carries no fence on either path. Cursors, sequences, and gap
semantics are unchanged; a consumer that already tolerated waiting sees the same
stream a little later, and one that read the store's files directly to get ahead
of the fence was never on this surface. Progress items and diagnostics are
transient and are not this surface: they are not durable truth, are not fenced,
and carry no compatibility expectation at all.

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
`:diagnostics_to`, `:cleanup_grace_ms`, and `:context_token_budget`; omission of
the context option selects the reference policy default of 8,192, while an
explicit valid value is forwarded unchanged as the required top-level Runtime
option. It passes `:project_manifest` and `:project_decision` through to the
runtime, and hands `:cleanup_grace_ms` to the session and the executor together
so a run's ending cannot report a period its cleanup did not run under.
`:process_probe` reaches the executor alone, which is where that option belongs.
It names four concrete implementations, so an embedder that
depends on it transitively acquires the reference adapters and their external
dependency whether or not every one is used. An embedder who wants a different
Store, Model, Executor, or ArtifactStore composes the ports and the `Loopex`
facade directly instead. See
[Runtime and embedding](runtime-and-embedding.md#technical-depth).

**Operator command.** `loopex run`, `sessions`, `resume`, `cancel`, and
`artifact`. The flags are `--policy`, `--state-root`, `--workspace`,
`--steer`, `--follow-up`, `--cleanup-grace-ms`, and
`--context-token-budget`, and each subcommand admits its own subset: `sessions`
and `artifact` take `--state-root` alone, `resume` and `cancel` take everything
but `--steer` and `--follow-up`, and only `run` takes those. The pairing is part
of the surface, so admitting a flag on one more subcommand is observable and
withdrawing one is breaking. A bare `--` ends option parsing and preserves every
remaining word as data, which is what makes an artifact locator beginning with
`--` retrievable at all. The reference command defaults a new prompt's context
value to 8,192; prepared `resume` and `cancel` recover an active run's committed
value on omission and refuse an explicit conflict before activation or abort.
The command's cross-application interrupt entries are `install/1`,
`install/2`, `install_prepared(attachment, cleanup_ms, activation)`, which
returns `:ok` or the owner's `{:error, reason}`, `activate_prepared(activation)`,
and `abandon_prepared(activation)`. Prepared installation binds the handler to
the attachment and the exact one-use capability and makes a holder process the
handler owns that capability's acknowledged holder; activation and abandonment
are presented from that holder and wait without a bound, a holder that dies
without answering is reported as `{:error, :prepared_activation_holder_lost}`,
and abandonment schedules no recovered work. `abandon_resume(attachment,
activation)`, the entry ADR 0016 names, is kept and presents the capability
from the same holder.
An unrecognised flag is refused rather than
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
