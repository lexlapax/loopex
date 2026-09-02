# Coding Sessions

<a id="concept"></a>
## Concept

M2 gives an operator a command. You stand in a Git repository, describe a change
in ordinary words, and watch a session read files, edit them, and run commands
until the work is done. The answer arrives as it is produced. Tomorrow,
`loopex sessions` finds the session again and `loopex resume` continues it.

The command is a peer surface and not the product. Every flow it offers is a
projection of the same embedded API an embedder calls: it owns no loop, no
durable session truth, no cursor truth, no store access, and no authority
decision. If the command disappeared, everything it does would still be
reachable.

This is a working milestone surface. It is not packaged, not installed, not
released, and carries no compatibility promise. An M1-era session data root is
**not** readable by M2: the durable record shape changed, and M2 will not open
one. Start a new state root rather than pointing M2 at an M1 directory.

Tools, host policy, and artifacts:
[Tools and policy](tools-and-policy.md#concept). Developer detail:
[Agent loop and tools](../developer/agent-loop-and-tools.md#concept).

<a id="operator-sessions-running"></a>
## Running a Task

Build the command from a checkout and run it from the repository you want it to
work in:

```text
MIX_ENV=prod mix cmd --app loopex_cli mix escript.build
cd ~/code/my-project
~/code/loopex/apps/loopex_cli/bin/loopex run --policy allow-all "add a changelog entry for the parser fix"
```

The build writes a self-contained `loopex` escript beside the application, and
`bin/loopex` is a small launcher that runs it. **Run the launcher, not the
escript.** The emulator reserves `SIGINT` for its own break handler and refuses
to hand it to a signal handler at all, so a `Ctrl-C` delivered straight to the
escript ends the operating-system process without stopping the run through the
public facade: the model call is left to finish on the provider's side, a tool
that was mid-write stays mid-write, and nothing is reported. The launcher traps
the interrupt outside the emulator and forwards the stop the escript already
knows how to make. Copy the pair together, keeping the launcher's
`../loopex` layout, or point `LOOPEX_ESCRIPT` at the escript and put the launcher
anywhere on your `PATH`. It reads the provider credential from
`LOOPEX_PROVIDER_API_KEY`.

`--policy` is required and has no default. Nothing runs a tool until you have
named the authority that governs it; see
[Tools and policy](tools-and-policy.md#operator-tools-policy).

Four options decide where the session's data and work live, how much
provider-visible context one request may admit under the repository estimator,
and how long a stopped run may spend stopping:

| Option | Meaning | Default |
| --- | --- | --- |
| `--state-root` | Where durable session records and artifacts are kept | resolved from `LOOPEX_HOME` |
| `--workspace` | The directory the tools act on | the current directory |
| `--context-token-budget` | Maximum estimated tokens in one exact provider-visible request | 8192 |
| `--cleanup-grace-ms` | How long stopping a running tool may take, in milliseconds | 5000 |

The context value is admission policy, not the provider model's published
capacity and not a billing estimate. It is committed when a new prompt starts a
run and reused by promotion and recovery; a current default never replaces an
active run's retained value.

The answer reaches standard output as the model produces it, in whatever
granularity the model adapter delivers. The shipped adapter streams, so an
answer appears as the model writes it rather than a turn at a time. What is
printed as it arrives is transient: the durable record of the turn is the
committed assistant message, which is built from the adapter's return value and
never assembled from what was displayed. An adapter that does not stream is
equally conformant, and against one the same answer simply appears complete at
the end of its turn. What the session is doing — each tool starting, each tool's outcome, and the run's ending — goes
to standard error, so `loopex run ... > answer.txt` keeps the answer and leaves
the commentary on your terminal.

<a id="operator-sessions-input"></a>
## The Four Things You Can Say

Prompt, steer, follow-up, and abort are four different things, and the command
gives each its own explicit affordance. The runtime never guesses which of the
two an input is, so neither does the command: input naming none of them is
refused rather than silently dropped.

| Input | How you say it | What it does |
| --- | --- | --- |
| Prompt | the positional words after `run` | Starts a run, only while the session is settled |
| Steer | `--steer "..."` | Joins the run already going, after the current tool batch and before the next model request |
| Follow-up | `--follow-up "..."` | Queues the next run, which starts only after the active run and its steering settle |
| Abort | an interrupt signal, or `loopex cancel` | Stops the run and reports what actually happened |

Naming both `--steer` and `--follow-up` is refused before a runtime, a store, or
an executor is started: a caller who supplied both has not said which they meant.

A steer that arrives too late is not lost and is not promoted into a follow-up.
It commits unapplied with a reason, and a steer is recorded applied only where a
committed request actually carried it.

<a id="operator-sessions-stopping"></a>
## Stopping a Task, and What Stopping Promises

Stopping reports what happened. It does not promise that what happened was
clean.

A run ends `cancelled` **only** where every owned operation reached a validated
terminal fact and every captured executor process group associated with those
operations was confirmed quiescent. Anything less
ends `outcome_unknown` and carries a reconciliation reference, which the
terminal prints:

```text
loopex: stopped, but the effect's outcome is unknown
loopex: reconcile with reconciliation_9f2c…
```

`outcome_unknown` means the effect's truth was not established. The work may
have taken effect. It is never retried blindly, and the terminal never reports it
as a cancellation, because an operator told "cancelled" about a process that may
still be running has been told something false.

That fail-closed rule also covers an executor integration that cannot report
cleanup. Every conforming executor supplies cancellation; a legacy integration
that omits it, or an executor that reports an error or unconfirmed cleanup, ends
the run `outcome_unknown` rather than letting absence stand for a clean stop.

**Ctrl-C works through `bin/loopex`, and only through it.** The Erlang emulator
reserves `SIGINT` for its own break handler and refuses to hand it to a program,
so the launcher catches the interrupt outside the emulator and forwards a
`SIGTERM` the command does handle; Ctrl-C then means what this page says
stopping means. Run the escript directly and a terminal Ctrl-C ends that process
without cleanup instead. The session survives either way — the durable record is
in the state root, not in that process — and `loopex cancel <session>`
reconciles it. Signals the command does handle are
`SIGTERM`, `SIGHUP`, and `SIGQUIT`; each becomes the same public abort and lets
the run report before the process goes, behind a backstop sized from the
session's own cleanup period so an interrupted terminal always exits.

A run that ends `failed` says why rather than printing the bare word. Where a
declared ceiling decided it, the ending names the category, whether it is
retryable, the dimension, what was observed, and the limit; where the reason is
a bare category — a provider call whose outcome nobody can state, for instance —
it names that:

```text
loopex: failed context_budget_exceeded (retryable false; context_tokens 9014 against 8192)
loopex: failed model_call_failed
```

Only those members reach your terminal. The private context, descriptors, and
provider text behind a failure never do.

<a id="operator-sessions-cancel"></a>
## `loopex cancel` Is Narrow

`loopex cancel <session>` reconciles a session that a dead process left behind.
That is the whole of its meaning.

It needs no `--policy`: it submits an abort and runs no tool. Where you name one
it is used, and where you do not it runs under an authority that permits nothing
— not under the permissive one, which applies only where you name it.

It applies only where no live `loopex` process holds the state root's placement
lock. Against a live owner it refuses and tells you which process is holding it:

```text
loopex: a live loopex process (pid 41022) owns this state root;
cancel from that terminal, or stop it first
```

That refusal is deliberate. Two runtime controls on one placement key would race
for ownership of every session in the root, and reconciling a session out from
under a running owner is exactly that race. A lock left by a process that is gone
is recognised as stale by asking the operating system whether that process is
still alive, not by waiting out a timeout, and is reclaimed automatically.

<a id="operator-sessions-finding"></a>
## Finding and Continuing Work

```text
loopex sessions
loopex resume <session> --policy allow-all
```

`sessions` lists the identifiers in the state root — the same strings you type
back to `resume` and `cancel`. A session resumes under the durable runtime
placement identity that created it; resuming through a different runtime identity
is refused with an explicit reason rather than silently taking ownership.

**A resumed session keeps the numbers it was started with.** Omit
`--cleanup-grace-ms` and `--context-token-budget` and `resume` and `cancel`
recover the values the session committed, rather than applying whatever this
process would default to today. Name one and it must agree with what the session
committed; a value that disagrees is refused before anything the session left
behind is scheduled, and the command says which one:

```text
loopex: :cleanup_grace_ms_configuration_conflict
```

Cleanup is compared first, then the context budget, so a command that got both
wrong is told about the one it has to fix first. A session that has already
settled reports no active context ceiling and therefore compares none: an
explicit ceiling there governs the next run rather than one that already ended.
A refusal gives the prepared owner up and releases this command's placement lock
before it reports, so the next attempt is not blocked by the failed one.

Nothing recovered runs until that check passes. Both commands take ownership and
rebuild the session's history first; `resume` then lets the recovered work go,
and `cancel` never does — it reconciles while that work stays paused, which is
what keeps a command asked to end a run from starting it.

<a id="operator-sessions-project-trust"></a>
## Project Resources Are Your Decision

A repository may carry a file such as `AGENTS.md` that is written to shape how an
agent behaves. Loopex will not put that content in front of the model unless you
decide it should be there.

The command looks for `AGENTS.md` at the root of the workspace — one label, no
recursion, no globbing — and tells you what it found, how large it is, and the
manifest digest a decision would bind, before the run starts. A discovery rule
you cannot predict is one you cannot meaningfully consent to. A decision binds the workspace, revision, manifest, and
content digests: change any of them and the decision no longer applies.

A run with no matching positive decision **fails closed toward withholding
content, not toward refusing to work**. It stages that class empty, journals a
declined receipt saying why, and runs the coding task without the project block.
At an interactive terminal the command asks you, having first shown you every
resolved path with its provenance and trust class and the manifest digest a
decision would bind:

```text
loopex: admit these project resources for this run? [y/N]
```

Only `y` or `yes` admits. Anything else withholds, and so does end of input — a
question nobody answered is not consent.

Where there is nobody to ask, the command does not ask. It reads that from the
input device rather than assuming it, and fails closed: a pipe, a redirect, and
any descriptor it cannot classify are all treated as absence, because a prompt
nobody can answer would otherwise be answered by whatever happened to be on
standard input. Such a run prints

```text
loopex: this terminal is not interactive, so no trust decision was taken; the
block is staged empty and the run continues without it
```

and takes the declined path above. There is no flag to admit project resources
non-interactively; the decision is one a person makes at a terminal or not at
all.

An admitted block changes no tool set, no policy decision, no bound, and no
grant. It is provenance-typed, budgeted, receipt-journalled data, never a grant
of authority.

<a id="technical-depth"></a>
## Technical depth

Developer companion:
[Agent loop and tools](../developer/agent-loop-and-tools.md#technical-depth).

### Commands

```text
loopex run --policy <name> [--state-root DIR] [--workspace DIR]
           [--cleanup-grace-ms MS] [--context-token-budget TOKENS] "<prompt>"
loopex run --policy <name> --steer "<text>" "<prompt>"
loopex run --policy <name> --follow-up "<text>" "<prompt>"
loopex sessions [--state-root DIR]
loopex resume <session> --policy <name> [--state-root DIR] [--workspace DIR]
              [--cleanup-grace-ms MS] [--context-token-budget TOKENS]
loopex cancel <session> [--policy <name>] [--state-root DIR] [--workspace DIR]
              [--cleanup-grace-ms MS] [--context-token-budget TOKENS]
loopex artifact <reference> [--state-root DIR]
```

Each subcommand names its own flags, and a flag is refused by name wherever the
subcommand does not offer it — `loopex sessions --policy allow-all` is refused
rather than quietly ignored:

| Subcommand | Flags |
| --- | --- |
| `run` | `--policy`, `--state-root`, `--workspace`, `--steer`, `--follow-up`, `--cleanup-grace-ms`, `--context-token-budget` |
| `sessions` | `--state-root` |
| `resume` | `--policy`, `--state-root`, `--workspace`, `--cleanup-grace-ms`, `--context-token-budget` |
| `cancel` | `--policy`, `--state-root`, `--workspace`, `--cleanup-grace-ms`, `--context-token-budget` |
| `artifact` | `--state-root` |

Naming the same flag twice is refused, and both numeric options are refused
before a runtime starts unless they are positive whole numbers within the
unsigned 64-bit domain. The parser accepts `--flag value`, `--flag=value`, and
bare positional words, and uses the standard library only: a dependency here
would land in an operator's install for the sake of flag parsing. A bare `--`
ends option parsing and keeps every remaining word as data, which is how an
artifact locator that begins with `--` is retrievable at all.

Exit status is `0` for success and `1` for a refusal or failure, with the reason
on standard error prefixed `loopex:`. An unrecognised subcommand, or no arguments
at all, prints the usage text there and exits `1`, so a script wrapping the
command can tell a run from a mistyped one.

### Where State Lives

| Path under the state root | Contents |
| --- | --- |
| `store.log` | The durable session record and public event log |
| `artifacts/` | Spilled tool output, content-addressed |
| `receipts/` | The executor's receipt ledger |
| `sessions/` | The session directory `loopex sessions` reads |
| `placement.lock` | The owning process identifier, for single-owner exclusion |
| `runtime_id` | The durable runtime placement identity sessions are recorded under |

The state root resolves from `LOOPEX_HOME` and never from Elixir application
environment, so the directory an operator's shell names is the directory used.

**Leave `store.log` alone while a command is running.** The store holds that
exact file, not the path: it records the file's identity at start-up and checks
it again while it holds the write handle. A log removed or replaced underneath a
live session is a write whose outcome cannot be stated, so the store stops
rather than answering with a new, empty, history-free log at the same name.

`loopex cancel` names the session and the class of the problem rather than
showing you the runtime term behind it:

```text
loopex: session s-4f21 could not be reconciled: its state store could not be opened or read
```

The other two classes are `its recorded history could not be replayed` and
`another process is already writing this state root's store`. The same care
applies to copies: a partial copy, a restored snapshot, or an edited log is a
history Loopex cannot prove, and it refuses rather than pretends. One log grows
to at most 256 MiB; past that it accepts no further append and does not reopen,
so a long-lived state root is one to retire rather than to prune by hand.

### Streaming, and What an Absent Stream Means

Two planes reach the terminal and they are not interchangeable. Durable events
are the record: the terminal's account of what happened is built from them, and
they are what a reconnecting reader replays. Progress deltas are transient
decoration that make the answer appear as it is produced.

Every delta and both closure items carry an opaque `stream_domain_id` naming the
one attempt that produced them. While the process-local owner remains able to
state the result truthfully, closure is an emission obligation and **not** a
delivery guarantee: a closure item rides the transient plane and may be
coalesced away or dropped under backpressure. Abrupt owner death, or recognized
executor owner loss before a durable terminal fact exists, may instead end that
plane without emitting a closure. A successor neither reuses nor closes the old
domain; it recovers the operation from the durable record.

A terminal that receives no closure therefore falls back to the durable record
exactly as it does for a sequence gap. It never reads an absence as abandonment
and never starts a timeout to decide, because that inference needs a timeout and
a timeout is a guess about a stream that may simply have been coalesced away.

The terminal's own patience is longer than the runtime's default wall-clock
deadline, so a run the runtime is still correctly running is never reported as
one this terminal has stopped following. Where the terminal does stop reading it
reports its own view and not the run's fate:

```text
loopex: stopped following this run; it may still be running
loopex: `loopex resume` continues reading from the durable record
```

### Interrupt Handling in Detail

`install/1` in `LoopexCli.Interrupt` is the compatibility entry. Production
uses `install(attachment, cleanup_ms)` for an ordinary active run and
`install_prepared(attachment, cleanup_ms, activation)` for recovered work that
must remain paused until the interrupt owner decides whether to activate it.
`abandon_resume(attachment, activation)` consumes that exact prepared pair
without scheduling recovered work. Installation sets `SIGTERM`, `SIGHUP`, and
`SIGQUIT` to `handle`, removes the runtime's own `:erl_signal_handler`, and
installs the command's handler on `:erl_signal_server`.

Removing the default handler is necessary rather than incidental: it stops the
emulator on `SIGTERM` immediately, which would race the abort the command
submits and end the process before the run could commit what it observed. Owning
termination means owning the case where cleanup never finishes. One checked
formula derives the command backstop from the session's committed cleanup
period, receipt-retention share, and terminal reserve. The command arms it once,
extends it once after durable abort admission, and never treats expiry as a
cleanup verdict. If it expires, it halts the process with status `130` while
watching the terminal that installed it, so a terminal that already reported
and exited is never halted after the fact.

`SIGINT` is absent from that set because `os:set_signal/2` refuses the name: the
emulator reserves it for the break handler. No amount of handler installation
changes that. The launcher supplies the missing half from outside the emulator:
it traps `INT`, `TERM`, `HUP`, and `QUIT`, forwards `SIGTERM` to the escript it
started as its own child, and reports the child's real exit status. It starts
the escript asynchronously rather than replacing itself with it, because a
process it had become could no longer be signalled on its behalf — and it saves
the incoming standard input first, since a shell would otherwise hand an
asynchronous child `/dev/null` and silently disable the project-resource prompt
and every piped invocation.

Stopping a tool is one budget, not a sequence of them. When a run ends while a
`bash` command is still going, the executor gives the command's process group a
cooperative window to leave, then signals it, then confirms it is gone — and
each of those steps receives only what remains of **one** process-cleanup period.
It defaults to five seconds. Bounded defensive teardown of a timed-out helper
may follow after that work allowance is spent.

Writing the receipt afterwards is bounded separately, by a declared share of the
period — a quarter — rather than by whatever the sequence left. The declared
work allowances therefore total five quarters of the configured period: six and
a quarter seconds at the default. That is an allowance total rather than a
strict wall-clock ceiling because bounded teardown may follow an exceeded bound.
The separate share is deliberate:
a job that spent everything fighting a stubborn process group would otherwise
reach its receipt with nothing left to write it with, and the job whose durable
record matters most would produce none. Every receipt names both the period it ran under, as
`cleanup_grace_ms`, and the bound its own write ran under, as
`receipt_retention_bound_ms`. The command itself is not consulted: a program that
ignores the first signal is killed when the period is spent, and a group that
cannot be confirmed gone makes the run's outcome `outcome_unknown` rather than
`cancelled`.

Confirming that a group is gone means running a program, and Loopex runs
`/bin/ps`. On an image that ships `ps` somewhere else, or not at all, nothing can
be confirmed and every command is reported `outcome_unknown` — correct, and
useless. A host embedding Loopex names the program
(`Loopex.Executor.Local.start_link(process_probe: "/usr/bin/ps")`), and every
receipt records which program was asked, so an unproven outcome says what could
not confirm it.

The period is yours to choose. `loopex run --cleanup-grace-ms 8000` declares it
for that session, and the run's ending reports whichever period applied, so an
operator reading `run.finished` always sees the number the stop was bounded by
rather than having to know what the default is. A host embedding Loopex passes
the same option to `LoopexComposition.start/1`, which hands it to the session and
to the executor together — one number, in both halves, so the ending cannot name
a period the cleanup did not run under.

The program is not yours to choose. A host embedding Loopex names it when it
starts the executor
(`Loopex.Executor.Local.start_link(process_probe: "/usr/bin/ps")`); the `loopex`
command takes `/bin/ps`. That gap is recorded as
[a known limitation](../evidence/M2-recorded-limitations.md#process-probe-not-session-visible).

### Migration From M1

There is none. M1's durable record shape is not M2's, M2 will not open an M1
state root, and no migration is provided or planned for an unreleased surface.
Point M2 at a fresh `--state-root`.

## Related

- [Tools and policy](tools-and-policy.md#concept) — the four coding tools, host authority, and artifacts.
- [Runtime operations](runtime.md#concept) — the M1 embedded runtime runbook.
- [Agent loop and tools](../developer/agent-loop-and-tools.md#concept) — the loop, contracts, and invariants behind this command.
- [Operator documentation index](README.md).
