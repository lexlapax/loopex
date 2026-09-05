# How a Run Works — Technical Depth

<a id="technical-depth"></a>
## Technical depth

Concept: [How a run works](how-a-run-works.md#concept).

This companion gives the ordering, the file layout, the numbers, and the
refusals behind the walkthrough. It states what is durable, what is not, and
what each failure leaves behind.

<a id="technical-run-planes"></a>
## Two Planes Reach Your Terminal

Concept: [The words on this page](how-a-run-works.md#concept-run-words).

**Durable plane.** Private journal records and public events are written in the
same store transaction and read back from the journal's outbox. They carry
stable identifiers and sequences, so a reader that reattaches gets the same rows
again. This is the record.

**Transient plane.** Streaming text, tool child bytes, and diagnostics are
decoration. Each stream belongs to one *attempt* — not one turn — and is named
by an opaque `stream_domain_id`; a retry opens a new domain and never reuses the
old one. A domain owes exactly one content-free closing item while its owner can
state the disposition truthfully, but that is an emission obligation and not a
delivery guarantee: a closure may be coalesced away or dropped under
backpressure, and an abruptly lost owner ends the plane with no closure at all.

The consequence is a rule the terminal follows and you can rely on: an absent
closure is never read as abandonment. The terminal falls back to the durable
record instead of starting a timeout, because a timeout would be a guess about a
stream that may simply have been dropped. Where it does stop reading, it reports
its own view rather than the run's fate.

The durable assistant message is built from the model adapter's return value and
is never assembled from what was streamed, so the record and the screen cannot
disagree about what the model said.

<a id="technical-run-durability"></a>
## What Is Durable at Each Step

Concept: [One run, from prompt to answer](how-a-run-works.md#concept-run-flow).

Every durable message on your screen is preceded by the record that authorizes
it, and the record and its public event are written in one transaction. The one
exception is the streamed answer text, which the table marks transient: it
reaches the screen as the model produces it and is committed only when the
turn's reply settles. Nothing on this table is published from a mutation reply.

| Step | Committed first | Then published |
| --- | --- | --- |
| Prompt admitted | `prompt_admitted_v2` — command digest, run id, content, the run's bounds and context ceiling | `user.message_appended`, echoed as `> ...` |
| Request staged | `model_request_committed` (canonical request bytes and their digest, applied steer, context receipt) **and** `model_attempt_opened_v1`, one transaction | `run.started`, on the first turn only |
| Model called | nothing | streamed text, transient |
| Reply settled | `model_attempt_settled_v1` | `assistant.message_appended` |
| Tool authorized | `effect_intent_committed` — the whole executor job **and** the host grant | `tool.started` |
| Tool finished | `executor_receipt_committed` | `tool.finished` with the outcome and any artifact references |
| Tool never ran | `tool_result_committed` | `tool.finished` carrying the reason, so a started call always finishes |
| Run ends | `run_terminal_committed`, or `outcome_unknown_committed` | `run.finished` |

Two orderings are load-bearing.

**The request row alone is not dispatch authority.** The committed request and
the attempt-open row are one transaction, and the attempt row is what permits a
provider call. A process that committed the request and died before the attempt
opened has staged a request nobody may send.

**The deadline becomes an instant exactly once**, when the run's first attempt
opens, and it is then read back from history rather than recomputed. A recovering
owner therefore resumes the deadline the run actually had instead of being handed
back the time it spent dead.

`run.finished` carries one of five outcomes: `completed`, `bound_reached`,
`cancelled`, `failed`, `outcome_unknown`. The last outranks all of the others.
A run holding an effect whose result nobody can state cannot honestly end
`completed` or `bound_reached`, and it is not resumed past that effect either —
feeding an unprovable result back to the model would continue a loop past an
ending that is already terminal.

A steer is read at exactly one point: after every tool result of the current turn
has committed, and after the bound checks have decided another request will
actually be staged. It is recorded `applied` only when an attempt opened over a
request that carried it. Otherwise it resolves `unapplied` with the bound name or
`run_terminal` as the reason, or `cancelled` on an abort — and it is never
promoted into a follow-up.

<a id="technical-run-state-root"></a>
## Where the Files Live

Concept: [What runs where](how-a-run-works.md#concept-run-parts).

Everything below is under the resolved state root, which comes from
`--state-root` or, absent that, from `LOOPEX_HOME`. It is never read from Elixir
application environment.

| Path | Written by | Contents |
| --- | --- | --- |
| `store.log` | the local store | The journal: append-only frames, each carrying a magic header, the payload size, a header digest, and a payload digest |
| `store.log.writer` | the local store | The writer marker that keeps two writers off one log |
| `artifacts/` | the artifact store | Content-addressed objects at `<2 hex>/<64 hex>`, with immutable use records under `uses/` |
| `receipts/` | the local executor | The ledger root: `generation`, the `claim` directory, `markers/`, `open/`, and one `<job digest>.receipt` per job |
| `sessions/<session id>` | the runtime | The entries `loopex sessions` lists |
| `runtime_id` | the runtime | The durable placement identity sessions are recorded under |
| `placement.lock` | the `loopex` command | The owning process, for single-owner exclusion |

Sizes and their refusals: one journal frame is at most 4 MiB and one log at most
256 MiB, past which the log accepts no further append; one artifact is at most
64 MiB and is refused rather than stored as a prefix; one tool may retain at most
8 MiB of spilled output. Nothing collects artifacts, so that directory only
grows.

Three integrity properties are worth knowing because they turn into refusals you
may see. The store holds the log's *file identity*, not its path, and re-checks
it after opening the append handle — a log removed or replaced underneath a live
session is a write whose outcome cannot be stated, so the store stops rather than
continuing into a new empty log at the same name. Replay does not trust the
frames: each is re-derived from the prior state and must match byte for byte,
and a mismatch is `{:invalid_history, index, detail}`, reported to you as
`its recorded history could not be replayed`. Artifact bytes are verified against
their digest and length on the way out, so a corrupt object reports unavailable
rather than handing you content it cannot vouch for.

The executor's ledger root carries authority, not cache. An entry is opened
before the effect starts and closed only when cleanup was confirmed, so an
unproven effect deliberately leaves its entry open — and an open entry left
stranded quarantines the root until it is reconciled. Treat that directory as one
intact administrative unit; the full disposition is in
[What local execution can reach](tools-and-policy.md#operator-tools-reach).

<a id="technical-run-bounds"></a>
## The Numbers You Control

Concept: [Where Ctrl-C enters](how-a-run-works.md#concept-run-interrupt).

Five numbers bound a run. The `loopex` command exposes two of them as flags; the
other three take the runtime's declared defaults, and a host embedding Loopex
sets them when it starts the runtime.

| Number | Set by | Default | What reaching it does |
| --- | --- | --- | --- |
| Max turns | runtime bounds | 16 | `run.finished` `bound_reached`, bound `max_turns` |
| Token budget | runtime bounds | 1,000,000 | `run.finished` `bound_reached`, bound `token_budget` |
| Deadline | runtime bounds | 600,000 ms | `run.finished` `bound_reached`, bound `deadline` |
| Context token budget | `--context-token-budget` | 8,192 | `run.finished` `failed`, category `context_budget_exceeded` |
| Cleanup grace | `--cleanup-grace-ms` | 5,000 ms | bounds how long stopping may take; ends no run by itself |

The first three are checked in a fixed order between turns, and the order carries
meaning: a reply with no tool calls is `completed` first and unconditionally, so
a run whose model stopped on its own is never reported as one that was cut off.
Then max turns, then the token budget, then the deadline.

Reaching a bound is not a failure and is not recorded as one. The ending names
the bound, what was observed, and the declared limit.

The deadline differs from the other two. They stop the run before another
provider call; the deadline also bounds work already in flight, so reaching it
can abort a request the provider may already have billed. It commits
`bound_reached` only where every owned operation reached a validated terminal
fact and every owned process tree was confirmed cleaned; otherwise the run ends
`outcome_unknown`. A deadline is not a guaranteed clean stop and nothing claims
it is.

The context ceiling is admission policy over one exact provider-visible request,
measured by a repository-owned estimator at one token per three canonical bytes,
rounded up. It is not the model's published capacity and not a billing estimate.
It can never produce `bound_reached`, because it refuses a request rather than
ending a run that ran its course.

**Cleanup grace is one period, and every observation window a stop uses is
derived from it.** For a period `g`: the receipt write reserves a quarter of it,
rounded up and never less than a millisecond; the cooperative window a tool
child gets to react to the termination signal is at most half of it; the
executor is watched for its answer for `max(10000, g + 2000)` ms; and the
terminal's own backstop is the executor's watch window plus the result reserve
plus the terminal reserve, which outlasts every window above it, so a session
configured to spend a long time stopping is not halted while its executor is
still inside the period it was promised. No window is derived from another
one's already-spent clock.

Stopping a tool child is one budget covering the whole sequence: a termination
signal sent to the child's *process group* rather than its leader, then the
cooperative window in which the child may finish a write and exit on its own,
then a kill signal to the group if it is still there, then confirmation that the
group is gone. Confirmation means running
a program — `/bin/ps` by default — and an image where that program is elsewhere
can confirm nothing, so every command is reported `outcome_unknown`. Each receipt
records which program was asked, the period it ran under as `cleanup_grace_ms`,
and its own write bound as `receipt_retention_bound_ms`.

An interrupt becomes the ordinary public abort. However many signals arrive, one
stop is submitted under one identity; acceptance extends the backstop exactly
once; and an answer the handler cannot classify leaves the backstop armed,
because a timeout is not a verdict about whether the abort committed. If the
backstop does expire, the process exits with status `130` — and it watches the
terminal that installed it, so a terminal that already reported and exited is
never halted after the fact.

<a id="technical-run-recovery"></a>
## Crash, and What Recovery Proves

Concept: [Where resume and cancel pick up](how-a-run-works.md#concept-run-again).

What a crash costs depends on which record had landed.

| Crashed at | What survives | What resume does |
| --- | --- | --- |
| Before the journal opened | nothing but a placement lock | The next command probes the recorded process incarnation, finds it gone, and reclaims the lock |
| After the prompt committed | the run, with no request staged | Stages the first request; the deadline has not started, so the downtime is not spent |
| After the request and attempt rows committed | the staged request and its fixed deadline | Re-presents the exact transaction; the deadline instant is read back, so downtime does count |
| While a tool was in flight | the effect intent and the host grant | Holds the work and opens a reconciliation query |
| After the receipt committed | the tool result | Continues the loop from the next decision |

**Preparation and activation are separate steps.** `resume` and `cancel` both
prepare: they contest and win ownership, the store advances the owner epoch
exactly once against the expected epoch and journal version, and the session's
complete history is rebuilt. Only the *scheduling* of recovered work waits. A
prepared owner is a real owner in every other respect — it answers status, it
accepts an attachment, and it admits an abort.

What is held back is fixed once, at preparation, rather than recomputed, so a
prompt admitted after you decided is not silenced by a decision that predates it.

**Activation is a one-use capability.** It is runtime-local, non-serializable,
and usable only by its current holder; it never enters a record, an event, a
snapshot, a progress item, or a diagnostic. The holder is the process that asked
for the preparation until `resume` installs its signal-manager guard and visible
handler, then asks the session coordinator to hand the capability to the exact
guarded holder. The coordinator alone linearizes that handoff and returns `:ok`
only after the guard has processed its commit. Death before that verdict fails
closed; death after it leaves the acknowledged holder live. Manager,
coordinator, or holder loss ends the exact authority rather than authorizing a
substitute. The capability has four states — prepared, spent, abandoned, fenced
— and only *spent* schedules anything. `resume` installs the interrupt handler sized by the period
this session committed (a period the sizing formula refuses would leave a fixed
ten-second backstop, and no such period can be committed), hands the
capability to its holder, and asks that
holder to spend it, waiting without a bound; the handler keeps handling signals
while it waits. `cancel` never spends it: it admits the abort
while the work is still held. An abort fences the capability *before* its store
transaction, so even an abort whose commit is unknown permanently blocks
activation. Abandoning is idempotent; activating is not.

**Reconciling an in-flight tool is an exact match, not a search.** The session
opens a query naming eleven facts: the query identifier, the current session
epoch, the expected executor identity, the current recovery contract, the
journaled operation identifier and original attempt, the journaled canonical
request digest, the original session and executor epochs, the origin executor
identity, and the origin fencing token. A receipt is admitted only where all
eleven agree *and* fifteen receipt fields match the journaled job, including
protocol version, job identifier, session, run, turn and tool-call identifiers,
the canonical request digest, both epochs at dispatch, executor identity, fencing
token, and the tool's identity and version.

A field the answer does not carry is a mismatch, never a match. An omitted field
can no longer satisfy an expected value that happens to be absent itself.

Where no provable receipt exists, the answer is `outcome_unknown`. That commits,
and it is terminal for the run. The effect is never redispatched merely because
its result is missing.

`loopex cancel` applies only where no live process holds the placement lock, and
is refused against a live owner rather than racing it. A lock this version cannot
read is not evidence its owner is gone: the process identifier is salvaged out of
the record and probed the same way, and only an absent process makes it
reclaimable. The refusals and their exact text are in
[`loopex cancel` is narrow](coding-sessions.md#operator-sessions-cancel).

<a id="technical-run-authority"></a>
## Authority, Refusal, and the Credential

Concept: [What makes this safe](how-a-run-works.md#concept-run-safe).

**The stances the command ships.**

| `--policy` | Allows | Refuses |
| --- | --- | --- |
| `allow-all` | every decision it is asked | nothing; it announces itself once, at the first call it decides |
| `shell-allowlist` | the filesystem tools, and `bash` whose first word is `cat`, `ls`, `pwd`, `echo`, `git`, `grep`, `head`, `tail`, or `wc` | every other command, with `policy_denied`; and any call it cannot read a command out of |
| none, on `loopex cancel` | nothing | every tool call, which is correct for a command that runs none |

A policy that raises, times out, or returns a malformed value becomes a denial
rather than falling through to allow. `defer` is declared in the port and refused
in this milestone rather than being treated as either answer. The decision is
made on the tool's generation triple rather than the model-supplied name, so it
cannot be steered by what the model chose to call something.

**A grant is not a token the executor trusts on sight.** Before any effect it
recomputes the canonical job bytes and digest independently, checks the tool
identity, version and effect class against its own definition, checks that the
workspace lease is held and its holder alive, checks the fencing token, and then
validates ten grant bindings: operation identifier, attempt, canonical request
digest, tool identifier, tool version, effect class, workspace lease, audience,
expiry, and fencing token. A missing binding and a wrong one are distinguished. A
job that fails any of this runs nothing, and the refusal is published durably
before the caller hears about it.

**Nothing about the credential is on disk.** It is read from
`LOOPEX_PROVIDER_API_KEY` by the model adapter and by nothing else, and passed as
a per-request option rather than stored in application state. It reaches no
journal record, no receipt, no artifact, no public event, no progress item, and
no diagnostic.

Every executor spawn removes that name explicitly, and the model-supplied command
then crosses `/usr/bin/env -i` and receives `PATH=/usr/bin:/bin` and nothing
else. Each receipt records the constructed environment's variable names and
whether the credential was present, so the claim is journalled rather than
asserted.

Provider failures are bounded before they can carry it anywhere. Every error from
the provider call is classified to `model_call_failed`, and the diagnostic text
kept internally has the credential's bytes substituted out *before* it is
truncated. Every raise, throw, and exit under that call is caught, and the call
runs in a monitored worker so a crash that arrives as a link signal is contained
too. An interrupted stream is an error, never a partial reply.

The shipped composition selects `anthropic:claude-haiku-4-5` and resolves its
endpoint from the adapter's bundled catalog, without a network call and without
the credential. Changing the model is a host decision, not a command flag.

## Related

- [How a run works](how-a-run-works.md#concept) — this page's concept companion.
- [Coding sessions](coding-sessions.md#technical-depth) — commands, flags, state layout, and interrupt handling in detail.
- [Tools and policy](tools-and-policy.md#technical-depth) — declared budgets, the policy port, grant validation, and the credential boundary.
- [Runtime operations](runtime.md#operator-runtime-recovery) — the embedded runtime's crash-recovery procedure.
- [Operator documentation index](README.md).
