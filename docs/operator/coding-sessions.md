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
~/code/loopex/apps/loopex_cli/loopex run --policy allow-all "add a changelog entry for the parser fix"
```

The build writes a single self-contained `loopex` file beside the application.
Copy it anywhere on your `PATH`; it needs nothing from the checkout it was built
from. It reads the provider credential from `LOOPEX_PROVIDER_API_KEY`.

`--policy` is required and has no default. Nothing runs a tool until you have
named the authority that governs it; see
[Tools and policy](tools-and-policy.md#operator-tools-policy).

Two options decide where the session's data and work live:

| Option | Meaning | Default |
| --- | --- | --- |
| `--state-root` | Where durable session records and artifacts are kept | resolved from `LOOPEX_HOME` |
| `--workspace` | The directory the tools act on | the current directory |

The answer streams to standard output as the model produces it. What the session
is doing — each tool starting, each tool's outcome, and the run's ending — goes
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
terminal fact and every owned process tree was confirmed cleaned. Anything less
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

**Ctrl-C is not one of the signals the command can handle.** The Erlang emulator
reserves `SIGINT` for its own break handler and refuses to hand it to a program,
so a terminal Ctrl-C ends the `loopex` process without cleanup. The session
survives it — the durable record is in the state root, not in that process — and
`loopex cancel <session>` reconciles it. Signals the command does handle are
`SIGTERM`, `SIGHUP`, and `SIGQUIT`; each becomes the same public abort and lets
the run report before the process goes, with a ten-second backstop so an
interrupted terminal always exits.

<a id="operator-sessions-cancel"></a>
## `loopex cancel` Is Narrow

`loopex cancel <session>` reconciles a session that a dead process left behind.
That is the whole of its meaning.

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

<a id="operator-sessions-project-trust"></a>
## Project Resources Are Your Decision

A repository may carry a file such as `AGENTS.md` that is written to shape how an
agent behaves. Loopex will not put that content in front of the model unless you
decide it should be there.

Discovery resolves a canonical, ordered set under declared path, per-file size,
and total limits, and shows you each path, its provenance, and the manifest
digest before you decide. A decision binds the workspace, revision, manifest, and
content digests: change any of them and the decision no longer applies.

A run with no matching positive decision **fails closed toward withholding
content, not toward refusing to work**. It stages that class empty, journals a
declined receipt saying why, and runs the coding task without the project block.
The command passes no decision of its own, so a non-interactive run is the
declined path by construction rather than by a flag someone has to remember.

An admitted block changes no tool set, no policy decision, no bound, and no
grant. It is provenance-typed, budgeted, receipt-journalled data, never a grant
of authority.

<a id="technical-depth"></a>
## Technical depth

Developer companion:
[Agent loop and tools](../developer/agent-loop-and-tools.md#technical-depth).

### Commands

```text
loopex run --policy <name> [--state-root DIR] [--workspace DIR] "<prompt>"
loopex run --policy <name> --steer "<text>" "<prompt>"
loopex run --policy <name> --follow-up "<text>" "<prompt>"
loopex sessions [--state-root DIR]
loopex resume <session> --policy <name> [--state-root DIR]
loopex cancel <session> [--state-root DIR]
loopex artifact <reference> [--state-root DIR]
```

Recognised flags are exactly `--policy`, `--state-root`, `--workspace`,
`--steer`, and `--follow-up`. Any other flag is refused by name. The parser
accepts `--flag value`, `--flag=value`, and bare positional words, and uses the
standard library only: a dependency here would land in an operator's install for
the sake of flag parsing.

Exit status is `0` for success and `1` for a refusal or failure, with the reason
on standard error prefixed `loopex:`.

### Where State Lives

| Path under the state root | Contents |
| --- | --- |
| `store.log` | The durable session record and public event log |
| `artifacts/` | Spilled tool output, content-addressed |
| `receipts/` | The executor's receipt ledger |
| `sessions/` | The session directory `loopex sessions` reads |
| `placement.lock` | The owning process identifier, for single-owner exclusion |

The state root resolves from `LOOPEX_HOME` and never from Elixir application
environment, so the directory an operator's shell names is the directory used.

### Streaming, and What an Absent Stream Means

Two planes reach the terminal and they are not interchangeable. Durable events
are the record: the terminal's account of what happened is built from them, and
they are what a reconnecting reader replays. Progress deltas are transient
decoration that make the answer appear as it is produced.

Every delta and both closure items carry an opaque `stream_domain_id` naming the
one attempt that produced them. Closure is an emission obligation and **not** a
delivery guarantee: a closure item rides the transient plane and may be coalesced
away, dropped under backpressure, or lost with the plane when its owner changes.

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

`install/1` in `LoopexCli.Interrupt` sets `SIGTERM`, `SIGHUP`, and `SIGQUIT` to
`handle`, removes the runtime's own `:erl_signal_handler`, and installs the
command's handler on `:erl_signal_server`.

Removing the default handler is necessary rather than incidental: it stops the
emulator on `SIGTERM` immediately, which would race the abort the command
submits and end the process before the run could commit what it observed. Owning
termination means owning the case where cleanup never finishes, so a backstop
halts the process with status `130` after ten seconds — while watching the
terminal that installed it, so a terminal that already reported and exited is
never halted after the fact.

`SIGINT` is absent because `os:set_signal/2` refuses the name: the emulator
reserves it for the break handler. No amount of handler installation changes
that, and this documentation does not imply otherwise.

### Migration From M1

There is none. M1's durable record shape is not M2's, M2 will not open an M1
state root, and no migration is provided or planned for an unreleased surface.
Point M2 at a fresh `--state-root`.

## Related

- [Tools and policy](tools-and-policy.md#concept) — the four coding tools, host authority, and artifacts.
- [Runtime operations](runtime.md#concept) — the M1 embedded runtime runbook.
- [Agent loop and tools](../developer/agent-loop-and-tools.md#concept) — the loop, contracts, and invariants behind this command.
- [Operator documentation index](README.md).
