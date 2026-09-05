# M2 recorded limitations

Retained record of known non-conformances carried by milestone `M2`. Part of the
[evidence index](README.md).

This file is a record, not a decision. Each entry names a rule the milestone does
not fully satisfy, why, what an operator can observe as a result, and the
authority that disposed it. An independent reviewer reads these as declared
limitations rather than as undiscovered defects; nothing here authorises work or
changes a commitment.

<a id="operator-path-race"></a>
## Path resolution and the effect are not one operation

**Rule.** `M2-technical.md` obligation 4 requires refusal by every filesystem
tool of every path that escapes the workspace root through traversal, a symlink,
or a link chain. This entry is the detail behind the narrowing that obligation
now carries. `docs/operator/tools-and-policy.md` already discloses this race in
plain language rather than promising containment it cannot deliver, and says
separately that `bash` is not path-checked at all; the rule this entry qualifies
is the filesystem tools' containment, not a promise that guidance still makes.

**What this milestone does instead.** Containment is resolved and checked, and
the effect is then performed as a separate operation. Erlang's `:file` exposes
neither `openat` nor `O_NOFOLLOW`, so the check and the use cannot be made one
kernel operation without starting a child process, which the same obligation says
these tools do not do.

The dominant windows are closed, and each closure is proved by reverting it.
Directory creation walked the path with `mkdir_p`, which follows a symlinked
component, so a name swapped under a write could redirect it outside the
workspace: a reviewer's probe wrote `escaped-354.txt` outside a workspace and
escaped eight times in nine runs. Each level is now created with `File.mkdir/1`
and, where it exists, required by `File.lstat/1` to be a real directory. `edit`
had the same hole for longer: it committed through the same create-exclusive and
rename as `write`, which protects the final component, but never ran the
directory guard, so a reviewer redirected an edit onto a file outside the
workspace on the eleventh attempt. `edit` now runs the identical sequence.
Reverting either guard alone reproduces its escape in the retained cases.

What survives is narrow and applies to `read`, `write` and `edit` alike. A write
or an edit creates under a private name with `O_CREAT|O_EXCL`, which refuses a
symlink outright, and renames onto the target, which replaces a link rather than
following it, so the final component cannot be redirected. But nothing pins an
intermediate directory between the `mkdir`/`lstat` and the create, and a read
verifies the identity of what it opened only after opening it. A workspace being
manipulated concurrently can therefore still be raced, with low probability, to
read a file outside the workspace or to land a write or an edit outside it.

**What an operator can observe.** A coding tool acting on a workspace nothing
else is changing is contained. A model that runs a background process in its own
workspace through `loopex.bash` -- which it may -- and uses it to swap a path
component in a tight loop can, with low probability, cause a read to return bytes
from outside the workspace, or a write or an edit to land outside it. Both are
reachable only from inside the workspace the operator already granted, and
neither escapes the machine.

There is a second consequence, on availability rather than containment, and it is
recorded here because the same gap produces it. A path checked as a regular file
and swapped to a FIFO before it is opened leaves that open outstanding, and one
outstanding blocked open stalls every other `File.read` in the emulator until it
is paired -- with idle dirty IO schedulers, and whether or not the blocked
process is abandoned. Every session sharing the runtime is affected for as long
as it lasts. The static case is refused before anything is opened; the raced case
is the same window as above.

**Disposition.** Maintainer, 2026-08-27: record the limitation and amend the
promises it contradicts, rather than close the windows. A limitation cannot waive
an obligation the plan still asserts, so obligation 4 and the operator guidance
were both narrowed in the same revision to say what is true; this entry is the
detail behind that wording, not a substitute for it.

The alternative was shown and declined: performing the effects in a controlled
child process. It is worth stating precisely what that would and would not buy,
because an earlier draft of this record overstated it. Anchoring such a child's
working directory to the verified resolved parent closes the intermediate
directory window, and a child is killable by the operating system, which also
closes the stall above. It does **not** by itself close the final component: a
basename can still be swapped to an outside symlink before the open, and refusing
that needs a no-follow-capable open or a handle opened before the check --
neither of which `:file` provides, and both of which the child would have to
carry. That is the work a milestone revisiting this would take on, and the cost
is the distinction obligation 4 draws between tools that execute a command and
tools that do not.

**Retained manual probes.** The write and edit component-swap cases remain in
`apps/loopex_executor_local/test/coding_tools_test.exs`, tagged
`retained_manual_probe`. Run them only as a diagnostic, in an otherwise idle
checkout:

```sh
MIX_ENV=test mix test apps/loopex_executor_local/test/coding_tools_test.exs \
  --only retained_manual_probe --seed 0 --trace
```

They are defined only for that explicit include and are absent from the ordinary
suite and M2's deterministic Outcome 4 selector. Winning or missing a scheduler
race is not closure evidence: the locked deterministic containment cases and
their mutation records carry that burden, while these two probes preserve the
known reproduction shapes for investigation.

<a id="local-authority-trusted-root"></a>
## Local effect authority trusts the whole ledger root

**Rule.** [ADR 0016](../adr/0016-configured-cancellation-observation.md#concept)
makes one prepared Local ledger root the durable authority for effect admission,
receipt publication, cancellation, and recovery. Two conforming Local instances
using that same intact root cannot both authorize one operation, and unresolved
open truth quarantines the root instead of guessing that an effect did not run.

**What this milestone proves.** Genesis, admission, open, refusal, and receipt
records are serialized under one root-wide generation and first-writer claim.
Whole-root move or replacement and an isolated copied generation are refused in
the negative demonstrations. A captured command group or filesystem worker is
owned by the exact Local authority that launched it; a numeric pid or process
group is observation data and never becomes authority by itself.

**What the proof does not cover.** The ledger root is a trusted administrative
unit, not a tamper-proof store. Partial copy or deletion, restoring an earlier
snapshot, filesystem inode reuse, or an administrator rewriting generation,
open, refusal, or receipt records can remove or replay the facts the admission
protocol relies on. No in-process check can distinguish those changes from the
history they imitate. M2 claims neither automatic cross-root detection nor safe
recovery after such administrative mutation.

**What an operator can observe.** Restoring the root to a point before an open
effect while its old operating-system child may still exist can make a later
runtime unable to prove whether admitting the operation would duplicate it.
Depending on which facts survive, Local refuses or quarantines the root; if an
administrator deliberately forges a self-consistent older history, the durable
exactly-once argument no longer applies. The safe rollback procedure is to
positively terminate every authority and captured child that used the old root,
or reboot the host when that cannot be proved, then activate the prior source
against a fresh empty root. Application stop alone is insufficient because an
owned operating-system child can outlive it.

**Disposition.** Maintainer, 2026-09-01: accept the ledger root as the trusted
atomic administrative boundary and retain this limitation, as part of the
[recorded acceptance of ADRs 0015–0018](../developer/agent-context-map.md#disposition-adrs-0015-through-0018-acceptance-2026-09-01).
This records the boundary ADR 0016 already chose; it does not waive a failed
ledger check, authorize automatic cleanup, or turn unavailable authority into a
clean verdict.

<a id="cleanup-grace-not-session-visible"></a>
## Withdrawn: the cleanup period is session configuration after all

**This limitation was recorded and is withdrawn.** It said the cleanup grace was
executor configuration that no session could reach, against accepted ADR 0009's
requirement that it be a declared session configuration value with a default,
reported in the terminal outcome's evidence, and it carried a maintainer
disposition to defer that to a later milestone.

An independent review rejected the deferral: a recorded limitation cannot stand
in for an accepted ADR while the plan says that ADR is consumed unchanged, and
the choice was to implement or to amend the ADR. The maintainer chose to
implement. The first attempt was rejected in turn, and correctly: forwarding an
*executor* option and reading the number back off whatever receipt happened to
arrive is not a session configuration value. A run that produced no receipt
reported `nil` — an abort admitted before any executor answered, a run stopped
between turns, every recovery — which are exactly the endings the period matters
for, and no default existed at the session at all.

What `M2` does now:

- `Loopex.Executor.default_cleanup_grace_ms/0` is the one default, on the port,
  because two parties need the same number and a default written twice is two
  numbers that agree until one is edited;
- `Loopex.start_link(cleanup_grace_ms: …)` is a declared session option
  validated at start, and `loopex run --cleanup-grace-ms …` is the operator's
  way to name it;
- `LoopexComposition.start/1` forwards it to the session and to the executor
  together, so the number the ending reports is the number the cleanup ran
  under;
- every run terminal record and every `run.finished` event reports it, from the
  session's own declaration, whatever the run did or did not dispatch.

The anchor is kept so links to it resolve. Nothing here is a live limitation.

<a id="process-probe-not-session-visible"></a>
## The program that confirms a process group is executor configuration

**Rule.** ADR 0009 requires the cleanup grace to be a declared session
configuration value. It says nothing about the program that confirms a process
group is gone, which is this executor's own mechanism rather than a contract
term.

**What is true.** `process_probe` is a start option of the shipped local
executor. A host embedding Loopex names it
(`Loopex.Executor.Local.start_link(process_probe: "/usr/bin/ps")`); the `loopex`
command does not expose a flag for it and takes `/bin/ps`. Every receipt records
which program was asked, so an outcome that could not be confirmed says what
failed to confirm it. A replacement implements the same
`-e -o pid= -o pgid=` table dialect; the runtime parses exact PGID equality and
requires the probe's own Port carrier to appear as a PID-equals-PGID witness before
absence can confirm cleanup.

**Why it is recorded rather than fixed here.** An image that ships `ps` at
another path has every command reported `outcome_unknown` under the shipped
command, which is correct and useless. Making it an operator flag is a small
change; making it *unnecessary* is not, and the alternatives — reading
`/proc`, `kill(pid, 0)` over a retained group, or a platform-specific syscall —
are portability decisions rather than plumbing. This milestone names the program
and records the choice; it does not settle which mechanism a later milestone
should use.

**Consequence for an operator.** On an image without `/bin/ps`, cancel and
deadline endings report `outcome_unknown` with a reconciliation reference rather
than `cancelled`. That is truthful, and it is not the same as the cleanup having
failed.

## Executor cancellation callback

**Rule.**
[ADR 0009](../adr/0009-tool-executor-and-grant-contracts.md#concept) states that
apart from the progress parameter, "nothing else at this boundary moves", and
names the cancellation sequence among the things that are unchanged. M1's only
cancellation signal is workspace-lease loss: the executor watches the lease
process and terminates the job when it dies.

**What this milestone does instead.** `Loopex.Executor` gains one required
callback, `cancel/2`, which stops a single named job. Its exact return algebra is
`{:ok, :cleaned}`, `{:ok, :unconfirmed}`, or `{:error, term()}`. Only
`{:ok, :cleaned}` confirms cleanup; every other answer fails closed to
unconfirmed cleanup at the runtime facade.

**Why.** Outcome 8 requires an abort to cancel the in-flight executor job and
confirm cleanup before committing `cancelled`, and lease loss cannot express
that. A lease is per workspace, so revoking it ends every job using that
workspace and leaves the runtime unable to run further work there — a heavy and
surprising consequence for one interrupt. The coordinator also does not own the
lease; the host does. Without a per-job signal, an abort during a tool call
could only ever commit `outcome_unknown`, which fails the locked case and leaves
a real operating-system process running on the operator's machine after they
pressed Ctrl-C.

**Observable consequence.** The boundary is wider by one required callback. An
existing executor that omits it is no longer conformant without change. The
runtime facade remains defensive toward such a legacy or nonconforming module:
it reports cleanup unconfirmed rather than treating absence as proof that
nothing remains. The isolated executor named as the second implementation will
have to satisfy the callback.

**Disposition.** Maintainer, 2026-08-24: add `cancel/2` to the executor
behaviour. The alternatives considered and not taken were routing cancellation
through lease revocation, refactoring the local executor to non-blocking
execution first, and cancelling only the BEAM side while always reporting
`outcome_unknown`.

**What the absence now means.** A legacy or nonconforming executor that does not
export required `cancel/2` answers `unconfirmed` rather than `cleaned`. The
absence previously read as a clean stop, which is a statement about the executor
this repository ships and not about an arbitrary module: one may own an
operating-system process and export no cancellation, and `cancelled` was then
committed over a process tree nobody signalled and nobody looked at. The run
ends `outcome_unknown` with a reconciliation reference instead.

**Accepted instrument.** Three independent reviews made the same point, and it
is correct: a recorded limitation cannot amend an accepted ADR. This repository
freezes an accepted ADR byte-for-byte — `Mix.Tasks.Loopex.Status` requires an
accepted ADR to equal the candidate it binds apart from its status and
governance row — so there was no in-place amendment to make. The maintainer has
accepted
[ADR 0012](../adr/0012-executor-cancellation-capability.md#concept), which
records this narrow extension and exactly supersedes the conflicting executor
boundary clauses in ADR 0009 and ADR 0011. The ADR and
[ADR index](../adr/README.md) are the canonical current-status sources.

## Pre-staging deadline instant

**Rule.** [ADR 0010](../adr/0010-provider-continuation-and-context-staging.md#concept)
requires a prompt's absolute deadline instant at admission, and
[ADR 0011](../adr/0011-session-input-algebra-and-streaming.md#concept) requires a
promoted follow-up's instant in the promotion commit, so that a recovering owner
re-presents it rather than handing the run back the downtime it slept through.

**What this milestone does instead.** Prompt admission commits the declared
*duration*, and promotion deterministically inherits that duration. The absolute
instant is fixed when either kind of run stages its first request, and is reused
unchanged by every later turn of that run.

**Why.** A clock reading inside a durable record that a successor may rebuild is
exactly what made a command-admission record a function of the clock rather than
of the command. Re-presenting one command then produced different bytes for the
same transaction identifier, and the store correctly refused to resolve the
transaction it was holding. M1's `commit_unknown` fault-injection lane caught
that during this milestone's own implementation, and the same hazard applies to
any record a successor may rebuild — including a run's terminal record.

Satisfying ADR 0010 and ADR 0011 literally requires a durable commit instant.
The Store contract stamps none, and adding one is a persistent-schema decision in
[ADR 0006](../adr/0006-store-transaction-and-owner-epoch.md#concept) territory.
That decision was deliberately not taken inside this milestone.

**Observable consequence.** Bounded to one pre-staging interval per run. A
failure between prompt admission or follow-up promotion and that run's first
staged request gives the run its full declared duration at staging instead of
charging the outage. Nothing is lost, corrupted, or dispatched twice. The
difference is one of generosity, not of safety or determinism; after the first
request commits, all downtime counts against the immutable instant.

**Disposition.** Maintainer, 2026-08-24: keep the duration split and record the
deviation. The alternative considered and not taken was adding a durable commit
instant to the Store contract, which remains the conforming fix whenever that
decision is made.

**Accepted instrument.** The conforming code fix was not smaller than the
documentary one — a Store-stamped commit instant would change a public port that
every Store implementation must satisfy, and ADR 0006 is frozen in the same way
as ADR 0010 and ADR 0011. The maintainer has accepted
[ADR 0013](../adr/0013-run-deadline-commitment-at-first-request-staging.md#concept),
which records this deviation and exactly supersedes the conflicting deadline
clauses in ADR 0010 and ADR 0011. The ADR and
[ADR index](../adr/README.md) are the canonical current-status sources.

## Provider selection is not reachable from the command

**Rule.**
[Outcome 10](../plans/M2.md) promises an operator a real command, and the
[dependency direction](../../AGENTS.md) makes the Model boundary replaceable by
design: "shared policy never depends on a provider name". A surface that can
reach only one provider is not itself a violation, but it is a gap between what
the kernel supports and what an operator can ask for, and it is recorded here so
a reviewer reads it as declared rather than as undiscovered.

**What this milestone does instead.** `LoopexComposition.start/1` names one model
specification, `anthropic:claude-haiku-4-5`, and the `loopex` command exposes no
option to change it. Selecting another provider requires composing the ports
directly rather than depending on the shipped composition.

**Why.** The accepted plan pair scopes the composition to naming four concrete
implementations and the command to driving the public facade. Threading a model
specification through both is a small change, but it is a change to the command's
input surface and to the locked composition, and neither was in the envelope the
maintainer accepted. Operator-facing provider selection is deferred rather than
added inside an accepted milestone.

**What was proved anyway.** The adapter is provider-neutral in fact and not only
in intent. It was exercised at the boundary against four providers, each
resolving its identity, carrying the committed request, returning a correctly
parsed tool call, and reporting usage and a provider-supplied response
identifier:

| Provider and model | Identity endpoint | Tool call | Response identifier form |
| --- | --- | --- | --- |
| `anthropic:claude-haiku-4-5` | `https://api.anthropic.com` | correct | `req_…` |
| `openai:gpt-4o-mini` | `https://api.openai.com/v1` | correct | `resp_…` |
| `openrouter:qwen/qwen3-32b` | `https://openrouter.ai/api/v1` | correct | `gen-…` |
| `ollama:qwen3.5:27b` | `http://localhost:11434/v1` | correct | `chatcmpl-…` |
| `ollama:qwen3.6:35b-a3b-q8_0` | `http://localhost:11434/v1` | correct | `chatcmpl-…` |

`ollama:qwen2.5:7b` answered the same prompt without calling the tool. It
declares tool capability and the call reached it correctly, so this is a
statement about that model rather than about the boundary.

The Anthropic value is the per-call HTTP request identifier surfaced by the
streaming adapter and visible in the provider account, not the assembled
message identifier a non-streaming response may carry.

**A local provider can never be this milestone's real-call evidence.** An Ollama
response identifier is a per-process counter, not an identifier that exists in a
provider account. The
[real-call attestations](M2-real-call-attestations.md) are worth exactly the
external lookup a person performs against the provider's account, and there is no
account to look in. A local model is a usable provider and is never closure
evidence.

**Observable consequence.** An operator who wants a different provider cannot ask
the shipped command for one and composes the public ports themselves. Nothing is
lost, mis-recorded, or silently redirected; the command does what it says, for
one provider.

**Disposition.** Maintainer, 2026-08-24: record the gap and defer operator-facing
provider selection to a later milestone. The adapter's provider neutrality is
proved at the boundary and is not in question.

<a id="m0-gate-runner-known-issues"></a>
## Closed M0 gate runner defects observed during M2

**Rule.** M2 requires one exact-candidate re-proof of the immutable M0 gate on
each locked toolchain pair. A retry is diagnostic, not a pass, and unavailable
evidence is not GREEN.

**What was observed.** The closed runner has two operational defects. First,
`bash scripts/check-m0-gate.sh` is not re-runnable in a used checkout: fixture
residue from an earlier invocation can make a later invocation fail. Second, its
interpreter-absence probe maps every nonzero
`bash scripts/check-bootstrap.sh` exit to
`the aggregate still depends on python3 or jq (outcome 8)`. A status-digest
failure can therefore end with that unrelated final `M0 gate RED:` line.

**Evidence consequence.** Each required M0 lane is run once from a fresh clone
after `mix deps.get`, with `LOOPEX_PROVIDER_API_KEY` exported. Read the failure
body rather than treating the final `M0 gate RED:` line as the diagnosis. Neither
defect waives either required GREEN row, and a retry in the used checkout is not
retained as a pass.

**Disposition.** Maintainer, 2026-08-30: record both as known inherited-gate
issues and fix them after M2 closes through an M0 gate generation under
`amendment-transaction-v2`. This record does not amend M0, accept a future
proposal, weaken either M0 re-proof, or add the repair to M2 scope. Any future
proposal `A` still requires exact-SHA review and explicit acceptance, and its
`R` still requires the prescribed transition review.

<a id="item-byte-fixture-spelling"></a>
## Store item byte targets in the locked context corpus

**Rule.** [ADR 0017](../adr/0017-durable-context-admission-budget.md#concept)
defines `Store.normalize_and_measure_item/2` as returning the normalized item
with its required `kind` and `event_id` members restored to atom keys, and
`encoded_bytes` as the deterministic external-term size of exactly that
returned item, which is the item `Store.transact/2` commits.

**What is true.** Two Amendment 4 test files derived their byte targets from a
binary-spelled `"kind"`/`"event_id"` shape instead: `sized_record/1` and
`sized_event/1` in `apps/loopex/test/store_item_budget_test.exs`, and
`independent_record_size/1` in `apps/loopex/test/context_admission_test.exs`.
An atom key and its binary spelling differ by exactly three bytes in the
external term format, so those fixtures could not agree with the ADR, with
`store_item_budget_test.exs`'s own `bytes == term_to_binary(normalized)`
assertion, with the genesis equality it asserts, or with every existing test
that reads a committed record's `payload.kind`. The production normalizer was
never wrong; the fixture arithmetic was.

**Disposition.** Maintainer, 2026-09-01: correct those fixtures directly to
measure the atom-restored shape, without a gate amendment. The files are
locked by case name and minimum, which the correction preserves, not by digest.
This is an explicit maintainer override of the ordinary rule that a locked test
is not rewritten during implementation: the change corrects a fixture defect
to the accepted ADR's stated convention and alters no claim any case makes. The
correcting commit carries the same record in its message.

<a id="required-context-budget-at-runtime-start"></a>
## The required context token budget and the existing runtime-start corpus

**Rule.** [ADR 0017](../adr/0017-durable-context-admission-budget.md#concept)
makes `context_token_budget` a required top-level runtime option with no
default in Core; omission is refused by the same name as an invalid value, and
only the reference composition supplies the 8,192 default on an embedder's
behalf.

**What is true.** Nine locked test files and the shared agent-loop helper
started a runtime without the option, because they predate the ADR: the
agent-loop, runtime, session-lifecycle, tool-registry, cancellation, embedded
API, session-directory, command, and project-resource-trust corpora, and the
same correction reached the cancellation-observation, provider-attempt,
host-policy, prepared-recovery, and context-budget-command corpora once their
other reds cleared enough to expose it. Refusing
omission as the ADR requires made every one of those runtimes unstartable.

**Disposition.** Maintainer, 2026-09-01: add the option at every runtime start
in those files directly, without a gate amendment. No case name or minimum
changes, no assertion changes meaning, and the one order-sensitive case - a
runtime started with no options at all - keeps its general refusal because the
runtime identity is validated before the budget. This is the second explicit
maintainer override of the rule that locked tests are not rewritten during
implementation; each is recorded here and in its correcting commit.

<a id="adr-0015-0016-corpus-corrections"></a>
## Locked corpus corrections forced by ADR 0015 and ADR 0016

**Rule.** ADR 0015 closes the artifact port at four callbacks, and ADR 0016
commits the cleanup period on every job, publishes admission under a root-wide
claim before any effect, moves the effect into the caller's process, retains
receipts under the committed quarter reserve, keeps `cancel/3`'s sixty-second
bound for direct callers only, and bounds the open-index snapshot at 4,194,304
bytes. Several locked cases asserted the earlier shapes.

**What is true.** Each correction preserves every case name and minimum and
asserts what the accepted ADR now requires: test doubles implementing the
superseded three-callback artifact port gained `describe/2` (`coding_tools_test`,
`cli_test`, `local_authority_contract_test`); a cancellation-observation double
captured `self/0` inside an Agent callback, naming the Agent as its worker; a
shell fixture wrote `onen` where it meant `one` with a newline; five
coding-tools cases expected the executor's startup period on receipts, the
generic prestart refusal for an expired job, a ledger holding nothing but
receipts, and a retention bound of at least the period; one expected the caller
to die with the executor rather than return an unknown outcome with the group
confirmed cleaned; and the sixty-second host-cancellation case drove production
abort, which ADR 0016 routes through `cancel/4`. Reaching the 4,194,304-byte
snapshot ceiling with at most 1,024 entries also required the executor port's
opaque identifier bound to rise from 1,024 to 8,192 bytes.

**Disposition.** Maintainer, 2026-09-01: apply every correction directly, and
raise the identifier bound, without a gate amendment. This is the third explicit
maintainer override of the rule that locked tests are not rewritten during
implementation; the correcting commits name each file and clause.

<a id="receipt-envelope-durable-projection"></a>
## The receipt envelope check and plain boundary data

**Rule.** Durable records carry plain boundary data; the Store refuses atoms as
values. ADR 0016 bounds the canonical retained receipt at 65,536 bytes.

**What is true.** One locked Local authority case validated the in-memory
receipt, whose `outcome` and `cleanup_confirmation` are atoms, as a Store
private record. That form is never retained; the runtime encodes those members
as strings before commit.

**Disposition.** Maintainer, 2026-09-01: validate the durable projection - the
receipt with its atom-valued members rendered as strings - directly, without a
gate amendment. Fourth recorded override; the case still proves the retained
receipt fits the item envelope.

<a id="adr-0017-corpus-corrections"></a>
## Locked corpus corrections forced by ADR 0017

**Rule.** ADR 0017 replaces the scalar `source_reference` with structured
descriptors, closes the project-resource refusal reasons and detail shape,
charges tools at their model-facing projection, admits a prompt as
`prompt_admitted_v2` with no `run.started` until its first request stages, and
refuses every non-active revocation state or non-null expiry as
`binding_changed/invalid_decision`. ADR 0016 replaced `session_genesis` with
`session_genesis_v2`.

**What is true.** Locked cases in the agent-loop, project-resource-trust,
session-lifecycle, embedded-API, command, and context-admission corpora
asserted the earlier spellings; each correction was verified against the
quoted clause by an independent reviewer before it was applied. Two fixture
defects were corrected in the same pass: the context corpus read `payload` on
public events its store double keeps flat, and one budget literal was tuned to
the tool charge ADR 0017 superseded. One helper race introduced by Amendment 4
itself - freezing the coordinator before any Control call was queued - was
corrected in the provider-attempt corpus.

**Disposition.** Maintainer, 2026-09-01: apply every correction directly,
without a gate amendment. Fifth recorded override; names and minimums are
unchanged and no assertion changes meaning beyond the accepted ADR.

<a id="adr-0018-corpus-corrections"></a>
## Locked corpus corrections forced by ADR 0018

**Rule.** ADR 0018 replaces the model-result and attempt-evidence records with
one settlement record, permits a retry only after an exact `not_dispatched`
settlement, closes the origin's stream from durable settlement, requires
Control to verify the prepared current owner on every permit, charges any
dispatched attempt without complete reported usage with the whole remaining
allowance, and classifies the shipped adapter's pre-transport refusals as
`not_dispatched`.

**What is true.** Thirty-one name-locked agent-loop cases, six provider-attempt
fixtures, and three adapter corpora asserted the earlier shapes; an independent
reviewer classified every failure against the quoted clause and separated the
two production defects it also found, which are repaired in production rather
than in any test. The three agent-loop cases Amendment 4 released by name were
rewritten to the ADR's shape under new names; the test double that proxies
Control now forwards provider dispatch with its original caller; and the
scripted model double reports usage by default, as a real provider does.

**Disposition.** Maintainer, 2026-09-01: apply every correction directly,
without a gate amendment. Sixth recorded override; minimums are unchanged and
the two production defects are fixed before any corrected case is counted.

<a id="embedded-api-and-command-fixture-structure"></a>
## Embedded-API case structure and command-corpus state roots

**Rule.** Under ADR 0017 a prompt admitted in a model-less runtime commits one
public event; every later event needs its own admitted command. State roots a
test creates must be unique across VM runs, or a directory a dying store
re-created after cleanup replays into an unrelated case.

**What is true.** Three embedded-API cases were built on a prompt producing two
events: one proved delivery identity over a single event, one paged its
snapshot scan at three events per iteration, and one used an abort whose
command identifier the same case re-issued later, so the second issue replayed
and committed nothing. The command corpus named its roots by a per-VM counter,
which produced the same paths run after run and a headless-journal flake the
store correctly refused.

**Disposition.** Maintainer, 2026-09-01: restructure the three cases with
fresh command identifiers and a reconnect-side event source, page at two
events per iteration across 513 iterations so the 1,024-event page limit is
still reached, and name roots by OS pid and random bytes - directly, without a
gate amendment. Seventh recorded override; names and minimums unchanged.

<a id="recovery-corpus-fixture-states"></a>
## Recovery corpus fixture states and host-driven reconciliation

**Rule.** ADR 0018 settles a recovered attempt that was open and dispatched as
owner loss with no second call. `next_event/1` answers an empty queue with a
transient empty result. Receipt reconciliation is host-driven: the host
presents a retained receipt to the solicited query and the runtime commits the
fact; the executor callback set stays closed.

**What is true.** Four locked recovery cases killed the predecessor mid-dispatched
attempt and expected the activated successor to continue the run, which the
locked ADR 0018 case with the same fixture shape forbids; they now lose the
owner at the durable prompt admission, before any attempt opens. The
configured-recovery helper treated the transient empty read as a failure, and
both its cases expected activation or cancellation to reconcile a retained
receipt on their own; they now reconcile through the attached host, and the
scripted reference model reports usage so an admitted turn is not charged the
whole remaining allowance.

**Disposition.** Maintainer, 2026-09-02: apply directly, without a gate
amendment. Eighth recorded override; names and minimums unchanged.

<a id="commit-title-baseline"></a>
## Commit-title enforcement baseline on the M2 branch

**Rule.** Commit titles are at most seventy-two characters; the repository check
enforces it from a fixed baseline over every reachable commit.

**What is true.** Nine commits on the milestone branch - seven integration
merges and two implementation commits - carry longer titles. Every one is an
ancestor of Amendment 5's bound candidate, so rewriting them would change that
candidate's identity and invalidate the acceptance record that names it.

**Disposition.** Maintainer, 2026-09-02: advance the check's baseline to
`e0354862fedde5939d7797c2adbf338d987ff538` so enforcement resumes from the
next commit, rather than rewrite bound history. Ninth recorded override; a
waiver of portable enforcement for exactly those nine commits.

<a id="corpus-adr-0018-supersession"></a>
## Corpus supersession to the ADR 0018 settlement shapes

**Rule.** Locked test names and minimum counts are immutable; assertion content
follows the accepted contract it proves.

**What is true.** ADR 0018 replaced three attempt records with one settlement
record, made a dispatched attempt without a readable answer terminal, closed the
reply key sets, and moved the publication fence ahead of the permit request.
After the implementation merged, an independent classification of every
remaining red found nineteen assertions that predated those decisions, nine
defects in test support, and three production regressions. The regressions
were repaired in product code. The corpus edits are:

- Nineteen supersessions: refutations of a record kind that now always exists
  discriminate on the settlement's `termination` or `conversation`; cases that
  expected a second dispatch after an unanswered or owner-lost attempt expect
  one dispatch and a terminal `owner_loss` or `failed` settlement with the
  estimated charge asserted on the record; the extra-key and oversized
  late-reply cases assert the compact refusal and size the eight-key durable
  reply without `canonical_request_bytes`; the abandoned-record and
  command-admission renames are completed in the files the rename missed.
- Nine test-support corrections: the Control-boundary proxy forwards the
  provider-dispatch call raw in all three modes; a byte helper measures the
  record the Store retains; a transposed `map_reduce` binding; the
  live-handoff case sequences succession at Control rather than through a
  hook that could not fire, and now also asserts the exact fence and
  ownership calls that precede a permit request; an abort issued through a
  superseded attachment; an atom compared as a string; the depth boundary
  values corrected to the projection's real depth; a vacuous refute renamed;
  an `on_exit` resume guarded against the coordinator's own shutdown.
- Three scoped rewrites: a settlement Store refusal is asserted as session
  unavailability with no fabricated settlement or terminal; nested provider
  fields are asserted refused rather than projected; the succession case
  scripts a `not_dispatched` first attempt so the run survives and both
  queues can be proved.
- Two additions: a boundary case proving the settlement preflight measures the
  record it commits (red before the repair, green after), and the
  abort-during-model-call bound derived from the cancellation reserve.
- The freeze helper in the provider-attempt suite tracks its own state rather
  than inferring it from the scheduler. That change is hygiene, not the
  repair: the suite's whole-file flake was then proved to be mailbox
  introspection of a suspended process, which cannot see a call still in
  the outer signal queue, and its repair is dispositioned separately.

**Disposition.** Maintainer, 2026-09-02, in two approvals: the classified set,
then a six-item addendum uncovered when the first set unblocked later
assertions. Tenth recorded override; review of each edit was waived, the
classification report and per-file before-and-after counts are retained with
the milestone's evidence.

<a id="adr-0017-step-five"></a>
## ADR 0017 evaluation step 5 is not implemented in M2

**Rule.** ADR 0017's evaluation order proves required-only record
admissibility before optional evaluation: a structural walk over a
structurally maximal instance of the project-receipt schema, a separately
resolved and measured required-only lower-bound candidate, and generated
evidence binding that implication at every list cardinality through 1,024.

**What is true.** No implementation and no evidence of step 5 exists in the
milestone. The admission path judges exactly the candidate it is handed. An
independent audit found the consequence that mattered live: a refusal on a
dimension that withholding cannot cure was built from the optional-inclusive
descriptor set while its counts described the required-only one, and its
project disposition claimed the project was never evaluated. That is repaired:
every retained refusal is now decided on and built from a required-only
candidate, and the live constructor refuses to describe a project-bearing
candidate as a required-only refusal. The residual gap is that the
required-only candidate carries the true project receipt rather than the
ADR's smallest exact receipt shape, so its byte bound is not a strict lower
bound; that can matter only within roughly one hundred fifty bytes of the
65,536-byte ceiling on the depth and cardinality path, which no M2 workload
reaches, and it is inert for the system-class and withholding dimensions.

**Disposition.** Maintainer, 2026-09-02: record step 5 as an approved M2
limitation. Implementing it changes what a replayed `observed` and
`record_byte_cost` mean on a byte refusal, from a final cost to a lower bound
the reducer today binds as equal, and that semantic decision belongs to the
milestone that implements it together with the generated cardinality
property. Thirteenth recorded override.

<a id="spent-attempt-retention"></a>
## Spent provider-attempt identities are retained for the ownership generation

**Rule.** ADR 0018: Control retains a spent attempt identity and its bound
worker for the complete ownership generation, so a successor coordinator can
never re-spend an attempt whose call may already have been billed.

**What is true.** Control's spent-attempt map grows by one bounded entry per
provider attempt for as long as Control holds the session, and is pruned only
when Control stops holding it. An independent audit flagged the growth for a
long-lived host. The growth is proportional to the session table Control
already retains, and a test now states the retention across succession so a
future prune turns red.

**Disposition.** Maintainer, 2026-09-02: accept as ADR-scoped. The successor
fence is worth the memory; a journal-derived bound would need an ADR-level
definition of a settled-past attempt and belongs to a later milestone.

<a id="dispatcher-store-io"></a>
## The event dispatcher reads the Store inside its own call handler

**Rule.** AGENTS.md, one serial session owner and distinct truth planes: one
session's work must not make an unrelated session's control traffic
unavailable.

**What is true.** The dispatcher answers `next_event` and attachment status by
reading the Store synchronously, under the Store's thirty-second call bound,
and Control acknowledges the publication watermark through an unbounded call
into that same process. When a host runs several sessions on one root and one
of them holds the single serial local Store in a large transaction, every
session's Control traffic can stall for up to that bound, and command routing's
five-second validation can report a merely busy session as unavailable. No
durable truth is lost or reordered; both are availability failures. The
shipped command runs one session per terminal and does not reach the trigger.

**Disposition.** Maintainer, 2026-09-02: record as an approved M2 limitation.
The root repair moves all Store reads out of the dispatcher process onto read
workers and redesigns queue, overflow, and invalidation ordering in the module
that owns publication; it changes a documented durability invariant and is
scheduled for the milestone that adds multi-session hosts, with the fence
cases extended to deferred reads.

<a id="closure-review-repairs"></a>
## Corpus repairs after the first closure review

**Rule.** Locked test names and minimum counts are immutable; assertion content
follows the accepted contract it proves.

**What is true.** The first independent exact-SHA closure review found that the
locked duplicate-permit assertion was refused on ownership before the one-use
check ran, and a follow-on sweep of the locked selectors for the same shape
found three more: no mutant reached the refusal-to-terminal indivisibility
guard, one context-receipt mutant was refused by the request digest rather
than the receipt relation, and one executor deadline case accepted a
pre-effect refusal as a mid-effect stop. Amendment 8 locked a new
duplicate-permit case; the other three were repaired inside their existing
cases with decisive mutants, and the receipt-relation repair also restaged the
four sibling mutants that the same digest had been refusing. One production
gap surfaced with the first: the indivisibility guard was applied to internal
rows only, and now also refuses a validly stamped command row inside a
refusal pair. Names and counts are unchanged.

**Disposition.** Maintainer, 2026-09-03: approved as the closure-review repair
set. Eighteenth recorded override; each repair carries its decisiveness
evidence in the worker report retained with the milestone's evidence.

<a id="post-closure-hotfix"></a>
## Post-closure hotfix on main outside an accepted plan

**Rule.** Product implementation belongs to a milestone: an accepted plan pair,
a red gate before implementation, and closure. A closed milestone's records are
frozen and its product baseline changes only through a successor.

**What is true.** An independent post-closure review of `main` at `86f1ccf`
found three shipped operator workflows failing in live use, each reproduced by
the integrator: a completed run cannot be resumed or cancelled from a fresh
process because the local Store's writer marker deliberately survives process
exit and the shipped composition never recovers it; the command's durable
command identifiers derive from a per-VM counter, so two fresh processes can
present the same identifier against one journal; and a second interrupt
delivered while the first is still joining exits the launcher and orphans a
signal-ignoring tool child under the init process with no terminal recorded.
Every gate, the full suite, and the retained evidence were green throughout,
because no locked case exercises a fresh operating-system process against a
completed run, a second VM against one journal, or a second interrupt against
a child that outlives the first.

**Disposition.** Maintainer, 2026-09-03: repair the three defects on `main` as a
hotfix ahead of the successor milestone, as a recorded override of the
plan-first rule, because each defect denies an operator a shipped workflow.
Later the same day the maintainer widened the override to every product
finding the review rated high, thirteen in all, ruling that none is postponed
to a successor: each is verified against the code first, a finding that does
not hold is refuted with the code path rather than patched, and each confirmed
one carries its own red-then-green test. The successor milestone inherits the
obligation to lock those tests in its gate. Nineteenth recorded override.


<a id="second-audit-hotfix"></a>
## Second audit: fourteen further product findings repaired on main

**What is true.** A second independent audit of `main` after the first hotfix
set, reviewed at `8f5309f8f26cffdc85218f2cf0313226ba44db66`, found six
blocking false-greens and eight high-severity defects while confirming the
common operator path, the suite, the provider gate, and the real-process
workflows sound. Three of the first review's fixes were judged complete, one
not fixed, and eight partially fixed at a boundary the first repair did not
reach. Each finding was verified against the code before repair.

**Disposition.** Maintainer, 2026-09-04: repair every product finding on
`main` under the same override as the nineteenth, with the same rules — a
finding is verified against the code first, one that does not hold is refuted
with the code path, and each confirmed one carries a red-then-green test. Three
decisions taken the same day: implement the acknowledged prepared-capability
transfer ADR 0016 requires rather than amend the decision; raise Mint to
1.10.0 for the two published HTTP/1 advisories and retake the real-provider
evidence; carry the digest-bound gate-isolation fixture collision to the
successor milestone rather than open a gate generation now. The successor
inherits the obligation to lock every test this override added. Twentieth
recorded override.

<a id="fourth-audit-release-repair"></a>
## Fourth-audit repair and verified source baseline

**Rule.** A post-closure repair does not reopen M2, advance its locked gate, or
create release authority. Publication, a package, and a version tag remain
separate governed decisions. Tests added outside M2's frozen gate are evidence
for the repaired source tree but are not silently promoted into that gate.

**What is true.** The repair range from `24f7f861147caf23103c84f96229204085d83670`
through `bf534bcca59e4533861e22deb7c1278bffa5dad3` closes the authority and
evidence gaps found after the fourth audit. Prepared interrupt installation arms
the exact signal-manager guard and exposes the handler before transfer. The session
coordinator fixes the guarded-path verdict, the installer forwards it to the
guard, and the guard acknowledges it before the coordinator records the holder
and answers. Installer death before forwarding fails closed; after forwarding,
ordered delivery preserves the handoff even if the reply is lost. Ordinary
`transfer_resume/2` remains an unguarded coordinator transfer. Handler
replacement installs the successor before draining predecessor holders, keeps
unfinished drains alive across installer death, serializes concurrent
replacement, and refuses replacement once an interrupt owns its abort and
backstop.

Provider dispatch takes Control's final deadline sample next to permit send and
checks the same committed deadline again in the receiving worker before adapter
entry. The Store reader used to rebuild that permit is owned by a guardian tied
to Control's lifetime, and adapter results retain their worker provenance until
admission. The complete raw reply now passes Store admission and canonical
validation before accounting. Nothing from a rejected reply is salvaged as
reported usage; only an already canonical reply compacted because its complete
durable settlement does not fit preserves validated reported usage.

The trusted-local executor distinguishes queue and join reservations from the
one exact operation-owner token, restores open authority after a partial close
or keeps the root claim when restoration cannot be proved, and uses a second
serialized permit decision to repeat reconciliation after final validation
before publishing admission and owner authority under one claim. An admission
that stops after its open entry installs no token and leaves the root
quarantined. A reservation made before another executor owner dies therefore
cannot outrun that owner's unresolved durable effect. Missing and oversized job identities are refused
before ledger or reservation work, and filesystem workers are tied to the Local
authority that admitted them. The serialized permit is the effect boundary: a
queued command whose permit has not been consumed is refused once its Local
owner is known dead; work admitted before owner loss is terminated and cannot
be reported as proved, while unresolved effect truth keeps the root
quarantined. The execute caller may leave after handing that one-use permit to
the launch worker; its later lifetime is not authority to revoke an already
admitted effect.

Artifact retention preserves the same stop truth as receipt and open-entry
administration. A worker confirmed stopped may lose only the overflow retrieval;
a worker not confirmed stopped bypasses receipt publication and leaves the
durable open entry to quarantine the root. The host store can therefore answer
late only into an already-unresolved operation, never behind a completed receipt
that cleared its authority.

**Frozen-source precedence.** One earlier sentence in the closed M2 Technical
envelope says that a valid usage pair remains reported when the reply itself is
unreadable. The same envelope's Outcome 1 instead requires an unreadable or
malformed live reply to consume the remaining allowance, and accepted ADR 0018
replaces the provider result/accounting projection with that conservative rule.
Under the repository's authority order the accepted ADR controls this repair.
The closed envelope is not edited here, and this record does not pretend the
older sentence agrees: current code and active guidance follow ADR 0018 and the
locked outcome.

**Disposition.** Maintainer, 2026-09-04: “Repair and release.” In the repository
state where `VERSION` remains `0.0.0`, no surface is labelled, and M2 explicitly
authorizes no package or publication, this instruction authorizes completing
and integrating the verified source baseline named above. It does not authorize
a version tag, package build or publication, registry upload, or other public
release. Those require their own accepted release-bearing decision. M3 inherits the
obligation to lock the tests added by this repair range, alongside the earlier
post-closure hotfix tests, before it can claim the corresponding protections.
Twenty-first recorded override.
