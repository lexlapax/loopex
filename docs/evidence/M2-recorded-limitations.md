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
failed to confirm it.

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
| `anthropic:claude-haiku-4-5` | `https://api.anthropic.com` | correct | `msg_…` |
| `openai:gpt-4o-mini` | `https://api.openai.com/v1` | correct | `resp_…` |
| `openrouter:qwen/qwen3-32b` | `https://openrouter.ai/api/v1` | correct | `gen-…` |
| `ollama:qwen3.5:27b` | `http://localhost:11434/v1` | correct | `chatcmpl-…` |
| `ollama:qwen3.6:35b-a3b-q8_0` | `http://localhost:11434/v1` | correct | `chatcmpl-…` |

`ollama:qwen2.5:7b` answered the same prompt without calling the tool. It
declares tool capability and the call reached it correctly, so this is a
statement about that model rather than about the boundary.

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
