# Tools and Policy

<a id="concept"></a>
## Concept

Technical depth: [Budgets, policy port, grants, and credential boundaries](#technical-depth).

A coding session is useful only if it can act. Loopex gives a session four tools
— `read`, `write`, `edit` and `bash` — that act on a real workspace on your
machine, and it puts a host policy in front of every one of them.

Authority is the host's, not the runtime's. Loopex owns the mechanics of running
a tool and stopping it truthfully; it has no opinion about whether a particular
call should be allowed. That decision belongs to the host policy you name —
`--policy` on the `loopex` command, `LOOPEX_POLICY` or `--policy` for a daemon or
the app server — and there is no default.

What this page lets you decide:

- which host policy stance governs a session, and what each stance really
  permits;
- how long stopping may take, and what a stop can and cannot prove;
- where oversized tool output goes and how to read it back;
- what reaches your disk in the clear, and where the provider credential goes.

Constraints stated plainly: tools run as your operating-system user, the
workspace root is a check rather than isolation, and nothing here is a sandbox.

Running, steering and stopping a session:
[Coding sessions](coding-sessions.md#concept). Developer detail:
[Agent loop and tools](../developer/agent-loop-and-tools.md#concept).

<a id="operator-tools-four"></a>
## The Four Tools

| Tool | What it does | Effect class | Retry class |
| --- | --- | --- | --- |
| `read` | Reads a UTF-8 text file beneath the workspace root, bounded, reporting truncation | `read_only` | `safe_retry` |
| `write` | Creates or replaces a file beneath the workspace root with exactly the bytes given | `workspace_write` | `safe_retry` |
| `edit` | Replaces one exact occurrence of a string, and reports what it found if the match is absent or ambiguous | `workspace_write` | `never_blind_retry` |
| `bash` | Runs a command in the workspace: `argv` for no shell interpretation, `command` for an explicit `/bin/sh` command | `process` | `never_blind_retry` |

`edit` and `bash` are `never_blind_retry` because repeating them is not the same
as doing them once: an edit that already applied would not match again, and a
command that already ran may already have changed something. Their per-tool
budgets are under [declared budgets](#operator-tools-budgets).

<a id="operator-tools-reach"></a>
## What Local Execution Can Reach

`read`, `write` and `edit` resolve paths against the workspace root and refuse
anything that escapes it, by `..` traversal or through a symbolic link. The
check is against the *resolved* path, so a link pointing outside is refused even
when its name looked contained.

Resolving a path and acting on it are two operations, not one. A workspace
nothing else is changing stays contained. A workspace being changed underneath
the tool — which a model can arrange, because `bash` can start a background
process in that workspace — can race that gap: a read could return bytes from
outside the workspace, and a write or edit could land outside it.

**The workspace root is a check this runtime performs, not isolation the
operating system enforces.** A raced path resolves with your own user's
permissions, so it can reach anything your account can — `~/.ssh/id_rsa`
included — not only the workspace you named. Naming a workspace is not a
sandbox. This is recorded as
[a known limitation](../evidence/M2-recorded-limitations.md#operator-path-race).

`bash` is not path-checked and cannot be. It starts in the workspace, runs as
you with your filesystem permissions, and can name any path its process can
reach. The protection that exists is the host policy you name plus the
containment above. The same user can also inspect or signal Loopex's own helper
processes. If a command deliberately disables its launch guard, Loopex refuses
to claim cleanup, reports the effect unproven and quarantines the executor's
ledger root; it does not claim that an unsandboxed command sabotaging the
cleanup mechanism can always be reaped synchronously.

Every process the executor starts has the provider credential removed
explicitly. A model-supplied command then crosses `/usr/bin/env -i` and receives
only a fixed `PATH`, so none of your shell variables reach it. The first
launcher process is also given an override that clears the environment names
present when it is assembled. The Erlang port environment extends the process
environment rather than replacing it atomically, so Loopex does not claim that a
name added concurrently elsewhere in the same VM cannot reach that first
launcher; the provider credential does not depend on that claim, because it is
removed explicitly.

<a id="operator-local-supervision-shell"></a>
### Local Supervision Prerequisite

The reference local executor requires an executable `/bin/bash` on Darwin and
Linux for its internal carrier and cleanup guard. Those scripts control
admission, process groups and cleanup; they do not change the interpreter a tool
asks for. A raw `command` still runs on `/bin/sh`, and an `argv` vector still
runs without shell interpretation. Core and other executors are unaffected.

Provide `/bin/bash` before using the reference stack. The executor does not
fall back to another shell when it is absent, and a failed launch is not proof
that an effect completed or that cleanup succeeded. The
[recorded implementation choice](../developer/agent-context-map.md#disposition-local-executor-bash-2026-09-07)
and [accepted ADR 0022](../adr/0022-local-executor-supervision-shell.md#concept)
set this prerequisite and its qualification requirements.

<a id="operator-tools-bounds"></a>
### Run and Cleanup Bounds

Every run declares a deadline duration when its prompt is admitted or its queued
follow-up is promoted. The absolute deadline begins when the run's first model
request is durably staged. A process loss before that staging does not spend the
duration; once staging commits, time an owner spends dead counts, and recovery
never extends the instant.

Every tool child runs in its own process group, and termination signals the
group rather than its leader, so a leader that spawned children and exited
cannot leave them running unattended. Each job runs under the earliest of the
run's committed deadline, the wall-time budget the session declared for it, and
the budget the tool's own definition names, so a bound cannot be widened by
declaring a larger one. The receipt records the instant the work actually ran
under.

Stopping a tool is one budget, the session's **cleanup period** (default five
seconds, set with `--cleanup-grace-ms`). When a run ends while a `bash` command
is still going, the executor sends the group a termination signal, gives it a
cooperative window to finish writing and exit, sends a kill signal if it is
still there, and then confirms the group is gone — and each step gets only what
remains of that one period. Bounded defensive teardown of a timed-out helper may
follow after the period is spent. The command itself is not consulted: a
program that ignores the first signal is killed when the period runs out.

Writing the receipt afterwards has its own declared share of the period — a
quarter, rounded up, and never less than one millisecond — rather than whatever
the stop sequence left. One formula fixes that share, and every path that
reserves time for a receipt reads it. The declared allowances therefore total
five quarters of the period, six and a quarter seconds at the default. That is an
allowance total rather than a strict wall-clock ceiling, because bounded teardown
may follow an exceeded bound. Every receipt names the period it ran under as
`cleanup_grace_ms` and its own write bound as `receipt_retention_bound_ms`.

Confirming that a group is gone means running a program, and Loopex runs
`/bin/ps`. On a system where `ps` is elsewhere or missing, nothing can be
confirmed and every stopped command is reported `outcome_unknown`. A host
embedding Loopex can name another program
(`Loopex.Executor.Local.start_link(process_probe: "/usr/bin/ps")`, or the same
option to `LoopexComposition.start/1`); the `loopex` command and the daemon
always use `/bin/ps`, which is recorded as
[a known limitation](../evidence/M2-recorded-limitations.md#process-probe-not-session-visible).
A replacement must implement the same `-e -o pid= -o pgid=` table: Loopex
requires exact PGID equality and the probe's own carrier row before it accepts
absence, so an empty or malformed answer confirms nothing. Every receipt records
which program was asked.

A group that cannot be confirmed gone makes the run's outcome `outcome_unknown`
rather than `cancelled`. Spilling truncated output into the artifact store is
part of the same settlement: if that worker cannot be confirmed stopped, no
receipt is written that could race its late publication, and the job stays open
and quarantines the ledger root until it is reconciled.

An executor takes part in stopping through its required `cancel/2`, which
answers `{:ok, :cleaned}`, `{:ok, :unconfirmed}` or `{:error, term()}`. Only
confirmed cleanup permits a clean cancellation; an error, an unconfirmed answer,
a failed call, or an executor module missing the callback is reported as
`outcome_unknown`. The local executor answers `cleaned` only once the job's
receipt, recording confirmed cleanup, is on disk, and `unconfirmed` otherwise; a
cancellation that arrives before the command starts is answered `cleaned` once
its refusal is durably published. The answer can be more cautious than the
record — a slow settlement can be answered `unconfirmed` while its receipt later
says `confirmed` — but never more confident. It is awaited until the job's
cleanup instant plus a margin of
`min(ceil(period / 4) + 1_000, max(10_000, period + 2_000) - period - 250)`
milliseconds; above a 7,000 ms period that margin no longer covers the whole
receipt allowance, so cautious answers become more likely.

Every window a stop uses — how long the executor is watched for its answer,
what its receipt write gets, what the caller is left with, and what the terminal
itself allows — is derived from the one committed period, never from another
window's already-spent clock. Declaring a longer period therefore buys a slow
but working executor real time instead of having it cut off and reported
unproven. The derived windows are listed under
[the numbers you control](how-a-run-works-technical.md#technical-run-bounds).

<a id="operator-tools-ledger"></a>
### The Executor's Ledger Root

The local executor's ledger root (`receipts/` under the state root) is part of
its authority, not a cache. An entry is opened before an effect starts and
closed only when cleanup is confirmed, so an unproven effect leaves its entry
open deliberately. Keep the root as one intact unit. Copying or deleting part of
it, restoring an older snapshot, reusing its filesystem identity, or rewriting
its records can erase the facts that distinguish an unfinished effect from one
that never started. Loopex may quarantine or refuse such a root, but it cannot
prove a forged or rolled-back history from inside that history.

Before rolling back or replacing a ledger root, positively terminate every local
executor and operating-system child that used it; if you cannot prove that,
reboot the host and then use a fresh, empty root. Stopping only the application
is not enough, and choosing another directory does not end the old root's effect
authority. The limitation and its disposition are retained in the
[recorded limitations](../evidence/M2-recorded-limitations.md#local-authority-trusted-root).

Generation records in the ledger must use the lowercase hexadecimal identity
[ADR 0016](../adr/0016-configured-cancellation-observation-technical.md#technical-depth)
requires. A record with uppercase letters is refused and the root is left
intact; the reader does not normalize, migrate or rewrite it. A digits-only
identity already satisfies the rule. If a root is refused, preserve it and follow
the termination and fresh-root procedure above. Nothing here grants permission to
delete a root or reboot a host.

Quarantine is checked each time a job is reserved, not once when an executor
starts, because several executors may share the root. An open entry stranded by
any of them refuses new effects until the root is reconciled — including on an
executor that was already running — and once it is reconciled, effects are
admitted again without restarting anything. Work in flight is not mistaken for
abandoned work: a root carrying two concurrent jobs stays usable, and a request
joins its own open entry rather than being refused by it. A short wait at a busy
root is contention, not unavailability, and comes out of the job's own remaining
time.

<a id="operator-tools-policy"></a>
## Host Policy

The policy decides every executor-backed tool call, including a read. There is
no exemption for "harmless" tools, because which tools are harmless is the
host's judgment.

A policy answers `allow`, `deny` or `defer`. A denial issues no grant, starts no
process, and commits a truthful denied outcome you see in the transcript:

```text
  · loopex.bash: denied
```

The run then continues or ends truthfully. It never retries a call the host
refused.

`defer` asks a person instead of deciding: the runtime commits a durable
question with its offered choices, a client answers it, and the policy is asked
again once the answer has committed. The answer is an input to that second
decision, never the decision itself. The app server's `ask` stance works this
way; see [app server operations](app-server.md#operator-app-server-launching).
The `loopex` command and the daemon ship no stance that defers, and the command
has no way to answer a question.

Failure fails closed. A policy that raises, times out after five seconds, or
returns a malformed value becomes a denial rather than falling through to allow.

Where you choose the policy:

| Surface | How it is named | Stances shipped |
| --- | --- | --- |
| `loopex run` and `loopex resume` | `--policy` | `allow-all`, `shell-allowlist` |
| `loopex cancel` | optional `--policy` | as above; without one, a stance that refuses every call |
| `loopex daemon` | `--policy` or `LOOPEX_POLICY`, once at start | `allow-all`, `shell-allowlist` |
| The app server | `LOOPEX_POLICY`, once at launch | `allow-all`, `ask` |
| An embedding host | `policy: YourModule` | any module implementing the port |

Under [the daemon](daemon.md#concept) the policy decides for every session and
every client of that daemon; no client request can name, replace or widen it,
and `run --daemon` refuses a `--policy` flag. A stance's notice is printed once,
on the daemon's own standard error, not on a client's terminal.

<a id="operator-tools-allow-all"></a>
## The Shipped Permissive Policy Is Not a Permission Model

`allow-all` allows every decision it is asked. It exists so you can run without
writing a policy module first, and it says what it is once per operating-system
process, at the first tool call it decides:

```text
loopex: the allow-all host policy is active. This is permissive local authority,
not a permission model: every tool call this session makes will be allowed.
```

It applies only where you name it. It is never a fallback or a default, and the
shipped composition refuses to start without a policy so that no embedder
inherits this one.

<a id="operator-tools-shell-allowlist"></a>
## A Stance That Refuses Something

`shell-allowlist` allows the filesystem tools and allows `bash` only when the
command's first word is one it names. Everything else is refused with
`policy_denied`, the refusal is reported, and the session carries on. It
announces itself once:

```text
loopex: the shell-allowlist host policy is active. Files may be read and changed,
and only these shell commands are permitted: cat, ls, pwd, echo, git, grep, head,
tail, wc. This is scope, not containment: it matches the leading word of a command
and a compound command defeats it.
```

**Read that last sentence literally.** This is scope, not a sandbox. It answers
"which commands did I agree to?" and nothing else. A compound command, a shell
function, an alias, or an interpreter given a script all reach past it without
effort. Containment is the executor's boundary and whatever isolation you place
around it. Do not deploy this stance as a security control. A call it cannot
read a command out of is denied rather than allowed.

Separate permissive stances ship in `loopex_cli`, `loopex_app_server` and
`loopex_reference_client`, because a client application may not depend on
another client. The duplication follows from that dependency rule.

<a id="operator-tools-artifacts"></a>
## Artifacts

A tool whose output exceeds its declared bound neither floods the conversation
nor silently loses the rest. The full bytes spill to an artifact store under
your state root, and the durable event carries the content digest, media type,
size, role and an opaque retrieval reference. Each shipped tool collects at most
8 MiB of output; a command that prints more has the remainder dropped, and the
result says so. The terminal prints the reference beside the tool's outcome as
the command that reads it back:

```text
    output beyond the tool's bound was retained: 240113 bytes,
    read it with `loopex artifact -- '3f9c1a…d80b'`
```

The model sees a bounded result naming what was truncated. You retrieve the
whole output with that command:

```text
loopex artifact -- '3f9c1a…d80b' > full-output.txt
```

The `--` is there because a locator's spelling is the store's own, and one that
began with `--` would otherwise read as a flag. A reference to nothing reports
`no artifact is retained for <reference>`, and one whose bytes are unreadable or
fail their digest reports `the artifact could not be read` rather than handing
you content it cannot vouch for. Clients of the daemon and the app server read
artifacts back in bounded, verified chunks instead; see
[artifact transfers](app-server.md#operator-app-server-artifacts).

The artifact holds exactly the bytes the command produced. The executor's own
notes — a nonzero exit status, or a process group that could not be shown to
hold only the command — appear only in the result shown to the model, and the
"N of M bytes shown" count covers only the command's bytes. A note states only
what was proved: it never says other processes were running, only that the
group could not be shown to hold the command alone, and whether cleanup of that
group was confirmed.

An artifact holds up to 64 MiB, and nothing collects artifacts. They stay under
the state root until you remove them; an artifact outlives the run that produced
it, which is the point of retrieving it later, and it is why that directory only
grows.

**Where there is no store, the rest is lost.** The executor takes its artifact
store from whoever composed it. The `loopex` command, the daemon and the app
server always supply one, but a host that composed none, or a store that refuses
the write, leaves the tool with a marker naming how many bytes existed and no way
to reach them. The receipt then records an empty artifact list, which is true,
and that is the whole of the warning.

<a id="operator-tools-disclosure"></a>
## What Is Kept on Disk, Unencrypted

The local store keeps **session records and artifact bytes unencrypted on your
local disk** under the state root. That includes your prompts, the model's
replies, the tool calls it made, and the output those tools produced — which is
the content of the files the session read.

Decide what to let a session read with that in mind. If a repository contains
material you would not want written to your state root in the clear, a session
that reads it will write it there. The provider credential is the one thing that
never enters that record; see [credential boundary](#operator-tools-credential).

<a id="operator-tools-skill-authority"></a>
## Skill Content Does Not Grant Authority

A project skill may contain instructions, supporting files, scripts and
supported metadata. Loopex treats all of it as inert content. Unsupported
execution or permission fields refuse installation rather than grant authority.
Installing or selecting a skill does not register a tool, choose a policy,
approve a tool call, widen a workspace lease or mint a grant.

Downloaded scripts do not run during installation or selection. If admitted
instructions later lead the model to request a script through `bash`, that
request crosses the same registered-tool, host-policy, grant, workspace and
executor checks as any other shell request. A field such as `allowed-tools`, a
hook declaration or a vendor-specific extension cannot bypass them.

`loopex skill add` asks its own narrow question: it shows the exact source,
commit and directory before fetching and requires an affirmative answer at a
terminal. That answer permits only the bounded acquisition jobs. It neither
admits the resulting skill to a session nor changes the policy of a coding run.

<a id="technical-depth"></a>
## Technical depth

Developer companion:
[Agent loop and tools](../developer/agent-loop-and-tools.md#technical-depth).

<a id="operator-tools-budgets"></a>
### Declared Budgets

| Tool | Wall time | Output bytes | Artifact bytes |
| --- | --- | --- | --- |
| `loopex.read` | 30,000 ms | 16,384 | 8,388,608 |
| `loopex.write` | 30,000 ms | 4,096 | 8,388,608 |
| `loopex.edit` | 30,000 ms | 4,096 | 8,388,608 |
| `loopex.bash` | 120,000 ms | 16,384 | 8,388,608 |

The read and shell ceilings leave room for both the durable receipt and the next
staged context inside the Store's 65,536-byte record ceiling. The local executor
reserves capacity for the receipt before starting an effect and measures the
complete receipt before retaining it; unusually large identity fields can shrink
the inline prefix further, with truncation or artifact retention reported in the
result.

All four carry version `1.0.0`. The `loopex.` prefix is reserved: the runtime
admits a tool with that prefix only through its own `:tools` start option, so no
tenant or extension can register a definition that shadows one of these.

<a id="operator-tools-policy-port"></a>
### The Policy Port

```elixir
@behaviour Loopex.Policy

@impl Loopex.Policy
def decide(request) do
  # request carries session_id, run_id, tool_call_id, the generation triple
  # {tool_id, tool_version, definition_digest}, arguments, effect_class,
  # idempotency_class, and workspace_lease
  {:allow, nil}
end
```

Select a shipped stance by name, or start the runtime yourself with
`policy: YourModule` through `LoopexComposition.start/1` or
`Loopex.start_link/1`. Omitting the policy refuses runtime start with
`:host_policy_required`.

The decision is made on the generation triple, not on the model-supplied name,
so a policy cannot be steered by what the model chose to call a tool. The
request carries no process identifier, credential or provider value.

| The callback returns | The runtime records |
| --- | --- |
| `{:allow, context}` in the bounded shape, or `{:allow, nil}` | a grant |
| `{:deny, category}` with a published category | a durable denial; nothing runs |
| `{:defer, question}` inside the admitted question family | a durable interaction; the policy is asked again once an answer commits |
| anything else, a raise, an exit, or no answer within 5 s | `{:deny, :policy_unavailable}` |

The durable interaction lifecycle — expiry, re-arming after a restart, and the
second evaluation — is fixed by
[ADR 0024](../adr/0024-durable-interaction-lifecycle-and-host-policy-authority.md#concept)
and described for operators under
[answering an interaction after a restart](app-server.md#operator-app-server-restart).

<a id="operator-tools-grants"></a>
### Grant Validation at the Executor

A grant is not a token the executor trusts on sight. Before any effect, the
executor validates audience, operation and attempt, the canonical request
digest, the lease, expiry and the fencing token. A job that fails any of those
runs nothing. [Authority, refusal, and the credential](how-a-run-works-technical.md#technical-run-authority)
lists every binding it checks.

Executor progress proves its identity, epochs, digest and fence before anything
narrower is projected; an event that fails validation is dropped and counted
rather than forwarded. The local executor emits bounded `bash` output before
completion with a zero-based sequence and contiguous byte offsets, and its
receipt count equals the callbacks it actually made. The filesystem tools may
emit no progress and report a count of zero.

<a id="operator-tools-artifact-references"></a>
### Artifact References

An artifact reference is a plain eight-member map. Its object identity is
`digest`, `size` and an opaque `locator`; its public interpretation adds
`media_type` and `role`; and its immutable use identity is
`use_canonicalization_version`, `use_digest` and the digest-derived
`use_locator`. Exact session, run, operation, attempt and tool-call provenance
stays in the private use record and is never copied into the reference.

The locator is the retrieval handle and carries no path you are expected to
construct. `loopex artifact` takes the reference, extracts the locator, and
retrieves through the `Loopex.ArtifactStore` facade. An embedder makes the same
read with `Loopex.ArtifactStore.retrieve(store, locator)`, which checks the
object's metadata and then fetches and verifies its exact identity and bytes. An
authorized host resolves private provenance separately with
`Loopex.ArtifactStore.describe(store, reference)`.

The local adapter publishes the content-addressed object and then its immutable
use record under `<state root>/artifacts`, syncing each before reporting
success. A failed use publication can leave an unreachable object behind but
never a successful reference to missing provenance. A round trip is byte-exact,
and a missing or corrupt object or use record reports unavailable rather than
returning empty content.

<a id="operator-tools-credential"></a>
### Credential Boundary

The provider credential is read from `LOOPEX_PROVIDER_API_KEY` once, by the host
that composes the runtime — the `loopex` command, the daemon, the app server, or
your own host through the reference composition — which moves it into private
custody and removes it from its own environment. A second composition in the
same process refuses rather than finding it again.

Every executor spawn removes that credential explicitly, including the launcher
and the executor's own process-management helpers, and a model-supplied command
runs through `/usr/bin/env -i` with `PATH` as its only variable. Each receipt
records that constructed environment and whether the credential was present, so
the claim is journaled rather than asserted.

Removing the variable changes only the running environment. The operating
system keeps a process's launch environment, which another process of the same
user can still read (`/proc/<pid>/environ` on Linux, `ps -E` on macOS) for as
long as Loopex runs, and a model's `bash` command runs as that user. Treat the
key as visible to that account, and run Loopex under an account whose processes
you trust.

The reference adapter runs provider code in one private companion process per
model call, with its crash output, standard output, standard error, logger and
direct IO suppressed before the provider starts. The credential reaches that
companion through a private channel only after the companion proves its
protected entry and build identity; it is never in the companion's arguments or
initial environment. A provider failure surfaces only its dispatch
classification and the fixed `model_call_failed` literal, never provider text.
The host must name the trusted interpreter, companion path, worker digest and
manifest digest explicitly — the command embeds them at build time, the daemon
and app server read them from the `.launch` file — and missing configuration
refuses before dispatch rather than searching the workspace for a binary or
running the provider in-process. A guardian watches the committed deadline
independently of a blocked provider and owns the companion's process group until
its cleanup is proved. [ADR 0019](../adr/0019-host-owned-provider-protection.md#concept)
fixes these boundaries.

<a id="operator-tools-skill-acquisition"></a>
### Skill Acquisition and Tool Authority

`loopex skill add` acquires a pinned Git import only after you authorize it.
Clone, commit verification, tree resolution and checkout are ordinary command
jobs in the local executor, each bounded to 30 seconds, in a closed Git
environment: no credential prompt, no ambient user or system configuration, no
submodule recursion, hooks or content filters. The selected skill is published
only after every file and identity check succeeds.

That authorization covers those jobs only. The retained pack carries no
executable authority. Resource admission changes model-visible data; running a
tool still requires a registered tool generation, a host-policy allow, a
matching workspace lease, and a grant the executor validates against the
complete job.

## Related

- [Coding sessions](coding-sessions.md#concept) — running, steering, resuming and stopping.
- [How a run works](how-a-run-works.md#concept) — where policy and the executor sit in one run.
- [Agent loop and tools](../developer/agent-loop-and-tools.md#concept) — the tool contract, registry and policy port in detail.
- [Compatibility surfaces](../developer/compatibility-surfaces.md#concept) — the experimental status of the tools, stances and artifact references.
- [Runtime operations](runtime.md#concept) — the embedded runtime beneath the command.
- [Operator documentation index](README.md).
