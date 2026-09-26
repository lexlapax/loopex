# Coding Sessions

<a id="concept"></a>
## Concept

Technical depth: [Commands, state, bounds and interrupts](#technical-depth).

The `loopex` command runs a coding task from your terminal. You stand in a
repository, describe a change in ordinary words, and watch a session read files,
edit them and run commands until the work is done. The answer streams as it is
produced. The session outlives the terminal: `loopex sessions` finds it again
and `loopex resume` picks it back up.

This page covers the command on its own, where each invocation composes a
runtime for itself and stops it when it ends. The same sessions can also be
driven through a long-lived [daemon](daemon.md#concept); the daemon page covers
those live forms. A first walk-through is in [getting started](getting-started.md).

What you can do with the command:

- start a run, steer it while it works, queue a follow-up, and stop it;
- reconcile a session a dead process left behind;
- list sessions and continue one;
- decide whether a repository's `AGENTS.md` reaches the model;
- install a skill from Git at an exact commit, inspect it, and select its
  instructions and supporting files for a run.

Constraints:

- The command is a peer surface over the embedded runtime. It owns no loop, no
  durable session truth and no authority decision; everything it does is also
  reachable through the embedded API.
- `--policy` is required wherever tools can run. There is no default.
- One `loopex` process, or one daemon, owns a state root at a time.
- It is built from source and is experimental; see
  [compatibility surfaces](../developer/compatibility-surfaces.md#concept).

Tools, host policy and artifacts: [Tools and policy](tools-and-policy.md#concept).
Developer detail: [Agent loop and tools](../developer/agent-loop-and-tools.md#concept).

<a id="operator-sessions-running"></a>
## Running a Task

Build the command once from a clean checkout, then run it from the repository
you want it to work on:

```text
MIX_ENV=prod mix cmd --app loopex_cli mix escript.build
cd ~/code/my-project
~/code/loopex/apps/loopex_cli/bin/loopex run --policy allow-all "add a changelog entry for the parser fix"
```

The build writes the `loopex` escript beside the application and builds its
private provider companion, `_build/prod/loopex_provider`, recording the
companion's absolute path and digests inside the escript. Keep the companion
where it was built; copying only the escript does not move it. The checkout must
be clean, because the build binds the exact source revision.

`bin/loopex` is a small launcher that starts the escript. **Run the launcher,
not the escript.** Only the launcher can turn a terminal Ctrl-C into a clean
stop; see [stopping a task](#operator-sessions-stopping). You may copy the
launcher and escript together, keeping the launcher's `../loopex` layout, or put
the launcher anywhere on your `PATH` and point `LOOPEX_ESCRIPT` at the escript.

The command reads the provider credential from `LOOPEX_PROVIDER_API_KEY` once,
when it first composes a runtime, and removes it from its environment. An empty
value or one above 65,536 bytes is refused. `run`, `resume` and `cancel` all
compose a runtime and so need the credential; `sessions`, `artifact` and
`skill` remove it without reading it. A missing or mismatched companion refuses
rather than running provider code inside the command's own VM. How the key
travels from there is under
[credential boundary](tools-and-policy.md#operator-tools-credential).

`--policy` names the host authority that decides every tool call; see
[host policy](tools-and-policy.md#operator-tools-policy).

Four options decide where the session's data and work live, how much
provider-visible context one request may admit, and how long stopping may take:

| Option | Meaning | Default |
| --- | --- | --- |
| `--state-root` | Where durable session records and artifacts are kept | `LOOPEX_HOME`; refused as `:loopex_home_required` when neither is given |
| `--workspace` | The directory the tools act on | the current directory |
| `--context-token-budget` | Maximum estimated tokens in one exact provider-visible request | 8192 |
| `--cleanup-grace-ms` | How long stopping a running tool may take, in milliseconds | 5000 |

The context value is admission policy, not the model's published capacity and
not a billing estimate. It is committed when a prompt starts a run and reused by
promotion and recovery; a later default never replaces an active run's value.

The answer reaches standard output as the model produces it. The shipped model
adapter streams, so text appears as it is written; an adapter that does not
stream simply shows the answer complete at the end of its turn. What is printed
as it arrives is transient: the durable record of the turn is the committed
assistant message, built from the adapter's return value rather than from what
was displayed. Everything else — each tool starting, each tool's outcome, and
the run's ending — goes to standard error, so `loopex run ... > answer.txt`
keeps the answer and leaves the commentary on your terminal.

<a id="operator-sessions-input"></a>
## The Four Things You Can Say

Prompt, steer, follow-up and abort are different requests, and the command gives
each its own affordance. The runtime never guesses which one an input is, so
neither does the command.

| Input | How you say it | What it does |
| --- | --- | --- |
| Prompt | the positional words after `run` | Starts a run, only while the session is settled |
| Steer | `--steer "..."` | Joins the run already going, after the current tool batch and before the next model request |
| Follow-up | `--follow-up "..."` | Queues the next run, which starts only after the active run and its steering settle |
| Abort | an interrupt, or `loopex cancel` | Stops the run and reports what actually happened |

Naming both `--steer` and `--follow-up` is refused before a runtime, a store or
an executor starts. A steer that arrives too late is not lost and is not turned
into a follow-up: it commits as unapplied with a reason, and a steer is recorded
as applied only where a committed request actually carried it. The terminal
shows each steer's disposition as `  · steer <command>: <disposition>`.

<a id="operator-sessions-stopping"></a>
## Stopping a Task, and What Stopping Promises

Stopping reports what happened. It does not promise that what happened was
clean.

A run ends `cancelled` **only** where every owned operation reached a validated
terminal fact and every captured executor process group for those operations
was confirmed gone. Anything less ends `outcome_unknown` with a reconciliation
reference, which the terminal prints:

```text
loopex: stopped, but the effect's outcome is unknown
loopex: reconcile with reconciliation_9f2c…
```

`outcome_unknown` means the effect's truth was not established; the work may
have taken effect. It is never retried blindly and never reported as a
cancellation. The same rule covers an executor that cannot confirm cleanup: an
error, an unconfirmed answer, or an integration that does not implement
cancellation ends the run `outcome_unknown` rather than letting silence stand
for a clean stop.

**Ctrl-C works through `bin/loopex`, and only through it.** The Erlang emulator
reserves `SIGINT` for its own break handler and will not hand it to a program,
so the launcher catches the interrupt outside the emulator and forwards a
`SIGTERM` the command handles. Run the escript directly and Ctrl-C ends that
process without cleanup: a model call is left to finish on the provider's side,
a tool that was mid-write stays mid-write, and nothing is reported. The session
survives either way — its record is in the state root — and
`loopex cancel <session>` reconciles it.

The command itself handles `SIGTERM`, `SIGHUP` and `SIGQUIT`. Each becomes the
same public abort and lets the run report before the process exits, behind a
backstop sized from the session's cleanup period so an interrupted terminal
always exits. If that backstop expires, the command exits with status `130`.

A run that ends `failed` says why. Where a declared ceiling decided it, the
ending names the category, whether it is retryable, the dimension, what was
observed and the limit; otherwise it names the bare category:

```text
loopex: failed context_budget_exceeded (retryable false; context_tokens 9014 against 8192)
loopex: failed model_call_failed
```

Only those members reach your terminal. The private context, descriptors and
provider text behind a failure never do.

<a id="operator-sessions-cancel"></a>
## `loopex cancel` Is Narrow

`loopex cancel <session>` reconciles a session that a dead process left behind.
That is the whole of its meaning.

It needs no `--policy`, because it submits an abort and runs no tool. If you name
one it is used; if you do not, it runs under an authority that permits nothing.
It still composes a runtime to open the session, so it needs the provider
credential in its environment.

It applies only where no live process holds the state root's placement lock.
Against a live owner it refuses and names the process:

```text
loopex: a live loopex process (pid 41022) owns this state root; cancel from that terminal, or stop it first
```

Two owners of one state root would race for ownership of every session in it,
and reconciling a session under a running owner is exactly that race. A lock
left by a process that is gone is recognised by asking the operating system
whether that process still exists, not by waiting out a timeout, and is
reclaimed automatically.

A lock record this version cannot read is not evidence that its owner is gone;
another `loopex` version is the likeliest writer. Where the record still names a
process identifier, that process is probed: an absent process makes the lock
reclaimable and a live one is refused like any live owner. A record naming no
process at all is refused as unverifiable:

```text
loopex: the placement owner could not be verified (…); establish that the recorded process is gone before changing the lock
```

You can clear either refusal by hand once you know the recorded process is
gone. `run` and `resume` apply the same lock and refuse a live owner with
`another loopex process (pid N) is using this state root; stop it, or pass --state-root to work somewhere else`.

<a id="operator-sessions-finding"></a>
## Finding and Continuing Work

```text
loopex sessions
loopex resume <session> --policy allow-all
```

`sessions` prints the identifiers recorded in the state root, one per line, or
`no sessions in this state root`. Those are the strings `resume` and `cancel`
take. `resume` replays the session's durable record from the beginning and
continues any work that was in flight. A session resumes under the runtime
placement identity that created it; resuming it through a different one is
refused with a reason rather than silently taking ownership.

**A resumed session keeps the numbers it was started with.** Omit
`--cleanup-grace-ms` and `--context-token-budget` and `resume` and `cancel`
recover the values the session committed. Name one and it must agree; a value
that disagrees is refused before anything the session left behind is scheduled:

```text
loopex: :cleanup_grace_ms_configuration_conflict
```

Cleanup is compared first, then the context budget, so a command that got both
wrong is told about the one to fix first. A settled session has no active
context ceiling to compare: an explicit value there governs the next run. A
refusal gives the prepared owner up and releases the placement lock before it
reports, so your next attempt is not blocked by this one.

Nothing recovered runs until that check passes. Both commands take ownership and
rebuild the session's history first; `resume` then lets the recovered work go,
and `cancel` never does — it reconciles while the work stays paused, which is
what keeps a command asked to end a run from starting it.

A tool the dead process had started is never run again to find out what it did.
`resume` settles it from the receipt the executor kept: where one was retained
the run continues with that result, and where none was the run ends
`outcome_unknown` with a reconciliation reference.

<a id="operator-sessions-project-trust"></a>
## Project Resources Are Your Decision

A repository may carry an `AGENTS.md` written to shape how an agent behaves.
Loopex puts that content in front of the model only if you decide it should.

The command looks for `AGENTS.md` at the root of the workspace — one file, no
recursion, no globbing — and before the run starts shows what it found: the
resolved path, its size, its content digest, its provenance and trust class, and
the manifest digest a decision would bind. A decision binds the workspace, its
Git revision where there is one, the manifest and the content digests; change
any of them and the decision no longer applies.

At an interactive terminal it asks:

```text
loopex: admit these project resources for this run? [y/N]
```

Only `y` or `yes` admits. Anything else withholds, and so does end of input.

A run with no positive decision **withholds the content; it does not refuse to
work**. It stages that block empty, journals a declined receipt saying why, and
runs the task without it. Where there is nobody to ask — standard input is a
pipe, a redirect, or anything the command cannot classify as a terminal — it
does not ask and prints:

```text
loopex: this terminal is not interactive, so no trust decision was taken; the block is staged empty and the run continues without it
```

There is no flag to admit project resources non-interactively. An admitted block
changes no tool set, policy, bound or grant: it is provenance-typed, budgeted,
receipt-journaled data, never authority.

<a id="operator-sessions-skills"></a>
## Install, Inspect, and Select Project Skills

Loopex discovers skills only under `.agents/skills/<name>/` in the selected
workspace. Each skill needs a `SKILL.md`; supporting files may sit beneath the
same skill directory. Home-directory skills, configured search paths, registry
search and content-directed discovery are not part of this surface.

You can install one directory from a Git repository at an exact commit:

```text
loopex skill add /path/to/skills-repository \
  --rev 0123456789abcdef0123456789abcdef01234567 \
  --path review
loopex skill list
loopex skill show git:<source-id>:review
```

`--rev` must be the complete lowercase Git object ID, 40 or 64 hexadecimal
characters. `--path` names one contained directory at that commit. The command
shows the source, commit and path and asks before fetching; a non-interactive
invocation cannot confirm and refuses the installation.

Installation and admission answer different questions. Installation verifies
the selected Git content and publishes it into the project's skills directory so
you can inspect it; it does not trust the skill for a run. On a later `run`,
Loopex shows the project skill identities and the complete manifest digest and
asks:

```text
loopex: trust this exact skill manifest for the next run? [y/N]
```

Changing any skill byte changes that identity.

Select instructions explicitly with `--skill`, and a manifested supporting file
of a selected skill with `--skill-resource`:

```text
loopex run --policy shell-allowlist \
  --skill review \
  --skill-resource review:references/checklist.md \
  "review the parser change"
```

Both flags may be repeated. If you name either and then decline trust, reach end
of input, or run without a terminal, the command refuses before submitting the
prompt, because the selection has nothing admitted to resolve against. Omit both
flags to run without skill content. If one unqualified name exists under more
than one source, use the source-qualified name `loopex skill list` prints.
`list` and `show` label a skill `manual only` when its metadata disables model
invocation; it stays inspectable and selectable by you.

Files in a skill are data. Installation runs no downloaded script, hook, tool or
vendor extension, and selecting a skill places only its admitted instructions
and the text resources you requested into the bounded model context. What a
skill cannot do is set out in
[skill content does not grant authority](tools-and-policy.md#operator-tools-skill-authority).

<a id="technical-depth"></a>
## Technical depth

Developer companions:
[Agent loop and tools](../developer/agent-loop-and-tools.md#technical-depth) and
[Compatibility surfaces](../developer/compatibility-surfaces.md#technical-depth).

<a id="operator-sessions-grammar"></a>
### Commands

```text
loopex run --policy <name> [--state-root DIR] [--workspace DIR]
           [--cleanup-grace-ms MS] [--context-token-budget TOKENS]
           [--skill NAME]... [--skill-resource NAME:LABEL]... "<prompt>"
loopex run --policy <name> --steer "<text>" "<prompt>"
loopex run --policy <name> --follow-up "<text>" "<prompt>"
loopex sessions [--state-root DIR]
loopex resume <session> --policy <name> [--state-root DIR] [--workspace DIR]
              [--cleanup-grace-ms MS] [--context-token-budget TOKENS]
loopex cancel <session> [--policy <name>] [--state-root DIR] [--workspace DIR]
              [--cleanup-grace-ms MS] [--context-token-budget TOKENS]
loopex artifact <reference> [--state-root DIR]
loopex skill add <git-source> --rev <full-object-id> --path <directory>
                 [--state-root DIR] [--workspace DIR]
loopex skill list [--state-root DIR] [--workspace DIR]
loopex skill show <source-qualified-name> [--state-root DIR] [--workspace DIR]
```

These are the offline forms. The live forms — `run`, `resume` and `sessions`
with `--daemon`, and `attach` — and `loopex daemon` itself are specified on the
[daemon page](daemon.md#technical-depth). Each subcommand accepts only its own
flags, and any other flag is refused by name rather than ignored:

| Subcommand | Flags |
| --- | --- |
| `run` | `--policy`, `--state-root`, `--workspace`, `--steer`, `--follow-up`, `--cleanup-grace-ms`, `--context-token-budget`, repeatable `--skill`, repeatable `--skill-resource` |
| `sessions` | `--state-root` |
| `resume` | `--policy`, `--state-root`, `--workspace`, `--cleanup-grace-ms`, `--context-token-budget` |
| `cancel` | `--policy`, `--state-root`, `--workspace`, `--cleanup-grace-ms`, `--context-token-budget` |
| `artifact` | `--state-root` |
| `skill add` | `--state-root`, `--workspace`, `--rev`, `--path` |
| `skill list`, `skill show` | `--state-root`, `--workspace` |

Naming a non-repeatable flag twice is refused. `--context-token-budget` is
refused before a runtime starts unless it is a positive whole number no greater
than 18446744073709551615. `--cleanup-grace-ms` is checked here only for being a
positive whole number; the runtime enforces the unsigned 64-bit ceiling when
composition reaches it. The parser accepts `--flag value`, `--flag=value` and
bare positional words, using the standard library only. A bare `--` ends option
parsing and keeps every remaining word as data, which is how an artifact locator
beginning with `--` stays retrievable.

Exit status reports the command, not the run. A refusal or command error exits
`1`, with the reason on standard error prefixed `loopex:`. A run the command
started and rendered to its end exits `0` whatever the run's outcome: a run
that failed, stopped at a bound, stopped with an effect's outcome unknown, or
ended any other way still exits `0`. Scripts must read the run's ending line on
standard error rather than the exit status to learn the outcome: `loopex: done`
is the only successful ending. The others are `loopex: failed …`,
`loopex: stopped at the … bound …`,
`loopex: stopped, but the effect's outcome is unknown`, and `loopex: <outcome>`
for any other ending, such as `loopex: cancelled` or `loopex: denied`. If no
ending arrives within the command's follow window, it prints
`loopex: stopped following this run; it may still be running`, still exits
`0`, and `loopex resume` continues reading from the durable record. An unrecognised subcommand, or no
arguments at all, prints the usage text and exits `1`. The interrupt backstop
exits `130`. The launcher exits `127` when it finds no escript. The live forms
and `loopex daemon` add their own statuses, listed on the
[daemon page](daemon.md#technical-depth).

<a id="operator-sessions-state"></a>
### Where State Lives

The state root resolves from `--state-root`, or from `LOOPEX_HOME`, and never
from Elixir application environment, so the directory your shell names is the
directory used. It holds the journal (`store.log`), the executor's receipt
ledger, spilled artifacts, the session directory `loopex sessions` reads, the
placement lock, the runtime placement identity, retained skill manifests and
their provenance, and a daemon's socket and index when one has run. The full
layout, with what writes each path and the size ceilings, is in
[where the files live](how-a-run-works-technical.md#technical-run-state-root).

**Leave `store.log` alone while a command is running.** The store holds that
exact file, not its path: a log removed or replaced underneath a live session is
a write whose outcome cannot be stated, so the store stops rather than answering
from a new, empty log at the same name. One log grows to at most 256 MiB; past
that it accepts no further append and does not reopen, so a long-lived state
root is one to retire rather than prune by hand. A partial copy, a restored
snapshot or an edited log is a history Loopex cannot prove, and it refuses
rather than pretends.

`loopex cancel` names the session and the class of the problem rather than the
runtime term behind it:

```text
loopex: session s-4f21 could not be reconciled: its state store could not be opened or read
```

The other two classes are `its recorded history could not be replayed` and
`another process is already writing this state root's store`.

Resource retention is separate from installation. A discovered manifest is
retained before a resource-enabled runtime starts. On `resume` or offline
`cancel`, the command first opens the session with recovered work paused, reads
its saved skill identity and closes that temporary stack; it then loads the
exact retained snapshot and opens the final runtime with the same provider and
executor. If the temporary cleanup cannot be confirmed, recovery stops before
opening the final runtime. Today's workspace cannot stand in for the admitted
snapshot: if that snapshot is missing or invalid, the command reports that skill
content is withheld and continues ordinary recovery, and requests whose complete
model-visible bytes were already staged remain recoverable from history.

Nothing collects retained resource snapshots. Back up the state root with its
session data, and do not prune `resource-packs/` for sessions you may need to
recover. `skill add` never overwrites an existing skill directory; an
interrupted import removes only its own staging directory. Retained provenance
is single-valued per content identity: when the same labels and digests already
carry a different origin, commit or tree, the new claim is refused and the first
retained bundle is kept. Use separate state roots to retain two origins for the
same bytes.

<a id="operator-sessions-bounds"></a>
### Skill Bounds and Format

| Bound | Ceiling |
| --- | --- |
| Packs in one manifest | 64 |
| Files in one pack | 64 |
| Retained content in one pack | 1 MiB |
| Complete manifest content | 64 MiB |
| Manifest metadata without content | 8 MiB |
| `SKILL.md` or another UTF-8 text resource | 64 KiB |
| Model-visible catalog | 16 KiB |
| Active skills in one run | 4 |
| Supporting files selected per skill | 8 |
| Supporting files selected per run | 32 |
| One requested supporting resource | 16 KiB, whole file or refusal |

These limits do not raise the request context budget or the Store's record
ceiling. When a catalog or selected file cannot fit its own ceiling or the whole
request budget, the optional block is withheld or the selection refused; Loopex
does not truncate it.

`SKILL.md` starts with bounded YAML frontmatter. `name` and `description` are
required, and the name must match the skill directory. The optional fields are
`license`, `compatibility`, `metadata` and `disable-model-invocation`; unknown or
duplicate fields refuse the pack. Ordinary files beside the skill directories,
such as a catalog `README.md`, are ignored. Directory links, unsupported file
types and invalid packs are refused before installation or admission. Git
acquisition itself is described under
[skill acquisition](tools-and-policy.md#operator-tools-skill-acquisition).

<a id="operator-sessions-streaming"></a>
### Streaming, and What an Absent Stream Means

Durable events are the record, and the terminal's account of what happened is
built from them. Streamed text is transient decoration. The terminal never
reads a missing stream closure as abandonment and never starts a timeout to
decide; it falls back to the durable record.
[Two planes reach your terminal](how-a-run-works-technical.md#technical-run-planes)
explains why.

The terminal waits longer than the runtime's default run deadline, so a run the
runtime is still running correctly is not reported as one the terminal stopped
following. Where the terminal does stop reading, it reports its own view, not
the run's fate:

```text
loopex: stopped following this run; it may still be running
loopex: `loopex resume` continues reading from the durable record
```

<a id="operator-sessions-interrupts"></a>
### Interrupt Handling

The launcher traps `INT`, `TERM`, `HUP` and `QUIT`, forwards `SIGTERM` to the
escript it started as its own child, and exits with the child's real status. It
starts the escript as a child rather than replacing itself, because a process it
had become could no longer be signalled on its behalf, and it hands the child
its original standard input so the project-resource prompt and piped input keep
working.

Inside the escript, the command sets `SIGTERM`, `SIGHUP` and `SIGQUIT` to be
handled, replaces the emulator's default signal handler — which would otherwise
stop the emulator on `SIGTERM` before the run could commit what it observed —
and turns each signal into the ordinary public abort. However many signals
arrive, one stop is submitted. A backstop derived from the session's committed
cleanup period is armed once and extended once after the abort is admitted; its
expiry is never read as a cleanup verdict. If it expires, the command exits
`130`, and it never halts a terminal that has already reported and exited.

`resume` hands recovered work to the interrupt handler before any of that work
runs, so there is no moment in which recovered work is running and an interrupt
would kill the process instead of stopping the run. The handoff protocol and the
interrupt module's entry points are specified in
[compatibility surfaces](../developer/compatibility-surfaces.md#technical-depth).

Stopping a tool, the receipt it writes and the bound on both are described under
[run and cleanup bounds](tools-and-policy.md#operator-tools-bounds). The
cleanup period is yours to choose with `--cleanup-grace-ms`, and the run's
ending reports the period that applied. A host embedding Loopex passes the same
option to `LoopexComposition.start/1`, which gives the one number to both the
session and the executor.

## Related

- [Getting started](getting-started.md) — a first session from a fresh checkout.
- [The daemon](daemon.md#concept) — the same sessions driven from separate processes through one long-lived daemon per state root.
- [Tools and policy](tools-and-policy.md#concept) — the four coding tools, host authority and artifacts.
- [How a run works](how-a-run-works.md#concept) — the flow of one run and what is durable at each step.
- [Agent loop and tools](../developer/agent-loop-and-tools.md#concept) — the loop, contracts and invariants behind this command.
- [Compatibility surfaces](../developer/compatibility-surfaces.md#concept) — this command's surface and what its experimental status means.
- [Operator documentation index](README.md).
