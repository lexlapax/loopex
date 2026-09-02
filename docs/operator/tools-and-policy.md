# Tools and Policy

<a id="concept"></a>
## Concept

A coding session is only useful if it can act. M2 gives a session four tools —
`read`, `write`, `edit`, and `bash` — that act on a real workspace on your
machine, and it puts a host policy in front of every one of them.

Authority is the operator's, not the runtime's. Loopex owns the mechanics of
running a tool safely; it owns no opinion about whether a particular call should
be allowed. That decision belongs to a host policy you name with `--policy`, and
there is no default: omitting the option refuses to start rather than picking one
for you.

Oversized tool output does not poison the conversation. Output beyond a tool's
declared bound is spilled to an artifact, the model sees a bounded result that
says what was truncated, and you retrieve the whole thing later by its reference
with `loopex artifact`.

Running, steering, and stopping a session:
[Coding sessions](coding-sessions.md#concept). Developer detail:
[Agent loop and tools](../developer/agent-loop-and-tools.md#concept).

<a id="operator-tools-four"></a>
## The Four Tools

| Tool | What it does | Effect class | Retry class |
| --- | --- | --- | --- |
| `read` | Reads a UTF-8 text file beneath the workspace root, bounded, reporting truncation | `read_only` | `safe_retry` |
| `write` | Creates or replaces a file beneath the workspace root with exactly the bytes given | `workspace_write` | `safe_retry` |
| `edit` | Replaces one exact occurrence of a string, and reports what it found if the match is absent or ambiguous | `workspace_write` | `never_blind_retry` |
| `bash` | Runs a command in the workspace: `argv` for no shell interpretation, `command` for an explicit shell | `process` | `never_blind_retry` |

`edit` and `bash` are `never_blind_retry` because repeating them is not the same
as doing them once. An edit that already applied would not match a second time,
and a command that already ran may have already changed something.

<a id="operator-tools-reach"></a>
## What Local Execution Can Reach

`read`, `write` and `edit` resolve paths against the workspace root and refuse
anything that escapes it, whether by `..` traversal or through a symbolic link.
The check is against the *resolved* path, so a link pointing outside is refused
even though the name that reached the tool looked contained.

Resolving the path and acting on it are two operations, not one. A workspace
nothing else is changing is contained. A workspace being changed underneath the
tool — which a model can arrange, since `bash` can run a background process in
the workspace it was given — can in principle race that gap: a read could return
bytes from outside the workspace, and a write or an edit could land outside it.

**Be precise about what that means.** The workspace root is a check this runtime
performs, not isolation the operating system enforces. A raced path resolves with
your own user's permissions, so what it can reach is everything your account can
reach — `~/.ssh/id_rsa` included — not merely the workspace you granted. An
earlier version of this page said such a read reached "nothing the operator did
not already grant"; that conflated the ambient access your OS user has with the
workspace you named to Loopex, and it was wrong. Granting a workspace is not a
sandbox, and this milestone does not claim to be one. It is recorded in full as
[a known limitation](../evidence/M2-recorded-limitations.md#operator-path-race).

`bash` is not path-checked and cannot be. It runs a command, and a command can
name any path its process can reach; it starts in the workspace and is confined
to it by nothing. That is the honest boundary, and the next paragraph is the
reason it matters.

`bash` runs a real command on your machine, as you, with your filesystem
permissions. That is the honest statement of its reach: **it is not a sandbox.**
Loopex does not isolate a tool child from your machine in this milestone, and the
protection that exists is the host policy you name plus the workspace-root
containment above.

Every process the executor starts explicitly removes the provider credential.
The model-supplied command then crosses `/usr/bin/env -i` and receives only a
fixed `PATH`, so no shell variable of yours reaches that command by accident.
The first launcher image is also given an override that clears the ambient names
present when it is assembled. Erlang's port environment extends the process
environment rather than atomically replacing it, so M2 does not claim that an
arbitrary name introduced concurrently elsewhere in the same VM cannot reach
that first image; the provider credential is removed explicitly after the
snapshot and does not depend on that broader claim.

Every run declares a deadline duration when its prompt is admitted or its queued
follow-up is promoted. The absolute deadline begins when that run's first model
request is durably staged. A process loss before first staging therefore does
not spend the duration; once staging commits, owner downtime counts and recovery
never extends the instant.

Every child runs in its own process group, and termination signals the group
rather than the leader, so a leader that spawned children and exited cannot leave
them running with nobody's name on them. Each job carries that committed absolute
deadline and the wall-time budget the session declared for it, and runs under the
earliest of that instant, that budget, and the budget the tool's own definition
names — so a bound cannot be widened by declaring a larger one.
Expiry enters the same cancellation sequence and each captured executor process
group associated with the run's operations is confirmed quiescent before the
run commits its bound, and the receipt records the instant the work actually ran
under.

An executor integration participates in that sequence through required
`cancel/2`, whose answers are `{:ok, :cleaned}`, `{:ok, :unconfirmed}`, or
`{:error, term()}`. Only confirmed cleanup permits a clean cancellation result;
an error, unconfirmed answer, failed call, or legacy module missing the required
callback is reported as `outcome_unknown`.

How long that answer is waited for is the session's cleanup period, not a number
this runtime invented. One committed period derives every observation window a
stop uses — how long an executor is watched for its answer, what its receipt
write gets, what the original caller is left with afterwards, and what the
terminal itself is allowed. So declaring a longer period with
`--cleanup-grace-ms` genuinely buys a slow-but-working executor more time
instead of having it cut off and reported unproven, and no window is ever
derived from another one's already-spent clock.

The Local executor's ledger root is also part of its authority, not merely a
cache directory. Keep that root as one intact administrative unit. Copying or
deleting only part of it, restoring an older snapshot, reusing its filesystem
identity, or rewriting its records can erase the facts that distinguish an
unfinished effect from one that never started. Loopex may quarantine or refuse
such a root, but it cannot prove a forged or rolled-back history from inside that
history. Before rolling back or replacing it, positively terminate every Local
authority and operating-system child that used it; if that cannot be proved,
reboot the host, then use the prior source with a fresh empty root. Stopping only
the application is not sufficient. The exact limitation and disposition are
retained in [M2's evidence record](../evidence/M2-recorded-limitations.md#local-authority-trusted-root).

The quarantine that root can carry is decided when a job is reserved, not once
when an executor starts, because the root is shared. An open entry stranded by
any executor using it refuses new effects until the root is reconciled — on an
executor that was already running when the entry was stranded, not only on the
next one to start — and once you have reconciled the root, effects are admitted
again without restarting the executor the quarantine had stopped. Work in flight
is not mistaken for abandoned work: a root carrying two concurrent jobs stays
usable, and a request joins its own open entry rather than being refused by it.
A moment's wait at a busy root is ordinary contention rather than
unavailability, and that wait comes out of the job's own remaining time and
never past it.

<a id="operator-tools-policy"></a>
## Host Policy

`--policy` names the module that decides every executor-backed tool call,
including a read-only one. There is no exemption for "harmless" tools, because
which tools are harmless is the host's judgment and not the runtime's.

A policy answers `allow` or `deny`. A denial issues no grant, starts no operating
system process, and commits a truthful denied outcome you read in the transcript:

```text
· loopex.bash: denied
```

The run then continues or terminates truthfully. It never retries a call the host
already refused.

Failure fails closed. A policy that raises, times out, or returns a malformed
value becomes a denial rather than falling through to allow. `defer` — asking a
person mid-call — is declared in the port and refused in this milestone rather
than being treated as either allow or deny.

<a id="operator-tools-allow-all"></a>
## The Shipped Permissive Policy Is Not a Permission Model

`--policy allow-all` selects a policy that allows every decision it is asked. It
exists so you can run the command without writing a module first, and it says out
loud what it is, once per operating-system process, at the first tool call it is
asked to decide:

```text
loopex: the allow-all host policy is active. This is permissive local authority,
not a permission model: every tool call this session makes will be allowed.
```

It applies only where you name it. It is never a fallback, never a default, and
the shipped composition an embedder depends on refuses to start without a policy
precisely so that no embedder inherits this one.

<a id="operator-tools-shell-allowlist"></a>
## A Stance That Refuses Something

`--policy shell-allowlist` selects the other stance the command ships. It allows
the filesystem tools and allows `bash` only when the command's first word is one
it names; everything else is refused with `policy_denied`, the refusal
is reported, and the session carries on. It announces itself the same way, once:

```text
loopex: the shell-allowlist host policy is active. Files may be read and changed,
and only these shell commands are permitted: cat, ls, pwd, echo, git, grep, head,
tail, wc. This is scope, not containment: it matches the leading word of a command
and a compound command defeats it.
```

**Read that last sentence literally.** This is scope and not a sandbox. It
answers "which commands did I agree to?" and nothing else. A compound command, a
shell function, an alias, or an interpreter handed a script all reach past it
without effort, and it is not built to stop any of them. Containment is the
executor's boundary and whatever isolation you place around it; this is you
saying which work you meant. Do not deploy it as a security control.

A call it cannot read a command out of is denied rather than allowed, because a
decision it cannot make is one it must not make in the model's favour.

Two permissive policies ship — one in `loopex_cli`, one in
`loopex_reference_client` — because a client application may not depend on
another client. That duplication is the honest consequence of the dependency
rule rather than an oversight.

<a id="operator-tools-artifacts"></a>
## Artifacts

A tool whose output exceeds its declared bound does not get truncated into the
conversation and does not silently lose the rest. The full bytes spill to an
artifact store under your state root, and the durable event carries the content
digest, media type, size, logical role, and an opaque retrieval reference. Your
terminal prints the reference beside the tool's outcome, already written as the
command that reads it back:

```text
    output beyond the tool's bound was retained: 240113 bytes,
    read it with `loopex artifact -- '3f9c1a…d80b'`
```

The model sees a bounded result that names what was truncated. You retrieve the
whole output by that reference:

```text
loopex artifact -- '3f9c1a…d80b' > full-output.txt
```

The `--` is there because a locator belongs to whichever artifact store the
command was composed with, and nothing constrains its spelling: one that begins
with `--` would otherwise be unreachable. A reference to nothing says
`no artifact is retained for <reference>` rather than printing emptiness, and a
reference whose bytes are unreadable or fail their own digest says
`the artifact could not be read` rather than handing you content it cannot
vouch for.

An artifact is held up to 64 MiB, and nothing collects it afterwards. Artifacts
stay under the state root until you remove them; an artifact outlives the run
that produced it, which is the point of retrieving one tomorrow, and it is also
why the directory only grows.

**Where there is no store, the rest is lost.** The executor takes its artifact
store from whoever composed it, and the shipped `loopex` command always supplies
one — but a host that composed none, or a store that refuses the write, leaves
the tool with the old marker naming how many bytes existed and no way to reach
them. The receipt records an empty artifact list, which is true, and that is the
whole of the warning you get.

<a id="operator-tools-disclosure"></a>
## What Is Kept on Disk, Unencrypted

The local store keeps **session records and artifact bytes unencrypted on your
local disk** under the resolved state root. That includes the prompts you wrote,
the model's replies, the tool calls it made, and the output those tools produced
— which is the content of files the session read.

This is stated plainly so you can decide what to let a session read. If a
repository contains material you would not want written to your state root in
the clear, a session that reads it will write it there. The provider credential
is the one thing that never enters that record: it stays a reference, never
reaches a journal, a fixture, a progress item, a diagnostic, or a tool child's
environment.

<a id="technical-depth"></a>
## Technical depth

Developer companion:
[Agent loop and tools](../developer/agent-loop-and-tools.md#technical-depth).

### Declared Budgets

| Tool | Wall time | Output bytes | Artifact bytes |
| --- | --- | --- | --- |
| `loopex.read` | 30,000 ms | 65,536 | 8,388,608 |
| `loopex.write` | 30,000 ms | 4,096 | 8,388,608 |
| `loopex.edit` | 30,000 ms | 4,096 | 8,388,608 |
| `loopex.bash` | 120,000 ms | 65,536 | 8,388,608 |

All four carry version `1.0.0`. The `loopex.` prefix is a reserved namespace: the
runtime admits a tool with that prefix only through its own `:tools` start
option, so a tenant or extension cannot register a definition that shadows a
bootstrap tool.

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

Select a shipped stance with `--policy` by name — `allow-all` or
`shell-allowlist` from this command, and the reference client's own permissive
policy in its own lane — or start the runtime yourself with `policy: YourModule` through `LoopexComposition.start/1`
or `Loopex.start_link/1`.

The decision is made on the generation triple and not on the model-supplied name,
so a policy cannot be steered by what the model chose to call a tool.

`{:defer, _}` is mapped to `{:deny, :interaction_unsupported}` in this milestone.
Omitting the `:policy` start option refuses runtime start with
`:host_policy_required` rather than starting a runtime that cannot authorise
anything.

### Grant Validation at the Executor

A grant is not a token the executor trusts on sight. Before any effect, the
executor validates audience, operation and attempt, the canonical request digest,
the lease, expiry, and the fencing token. A job that fails any of those runs
nothing.

Executor progress proves its identity, epochs, digest, and fence before anything
narrower is projected; an event that fails validation is dropped and counted
rather than being forwarded to the operator. The shipped local executor emits
bounded `bash` child bytes before completion with zero-based producer sequence
and contiguous byte offsets, and its receipt count equals the callbacks it
actually made. The filesystem and demonstration tools may emit no progress and
report a count of zero truthfully.

### Artifact References

An artifact reference is a plain eight-member map. Its object identity is
`digest`, `size`, and opaque `locator`; its public interpretation adds
`media_type` and `role`; and its separately immutable retention identity is
`use_canonicalization_version`, `use_digest`, and the digest-derived
`use_locator`. Exact session, run, operation, attempt, and tool-call provenance
stays in the private use record and is never copied into the compact reference.

The object locator is the retrieval handle and carries no path an operator is
expected to construct. `loopex artifact` takes the compact reference, extracts
that locator, and retrieves through the Core-owned `Loopex.ArtifactStore`
facade. An embedder makes the same public read with
`Loopex.ArtifactStore.retrieve(store, locator)`: Core calls validated
locator-only `stat`, then fetches and verifies the exact object identity and
bytes. An authorized host resolves private provenance separately with
`Loopex.ArtifactStore.describe(store, reference)`; ordinary retrieval neither
reconstructs nor accepts use metadata.

The local adapter publishes the content-addressed object and then its immutable
use record under `<state root>/artifacts`, syncing each before success. A failed
use publication can leave an unreachable object orphan but never a successful
reference to missing provenance. A round trip is byte-exact, and a missing or
corrupt object or use reports unavailable rather than returning empty content.

### Credential Boundary

The provider credential is read from `LOOPEX_PROVIDER_API_KEY` by the model
adapter and nowhere else. Every executor spawn explicitly removes that named
credential, including the launcher and the executor's own process-management
helpers. A model-supplied command is then launched through `/usr/bin/env -i`
with `PATH` as its only variable. The receipt records that constructed downstream
environment and whether the provider credential was present, so the command-side
claim is journalled rather than asserted. A provider error is bounded and has the
credential's bytes substituted out before any caller, report, or terminal can
see it.

A crash inside the provider library is covered by that too. The call the adapter
makes carries the credential in its arguments, so an error left uncaught there
could reach the emulator's own crash report with those arguments printed beside
it. Every raise, throw, and exit under that call is caught and reported as the
same bounded classification an ordinary provider failure produces, and an
interrupted stream is an error carrying a bounded, credential-substituted reason
for all three endings rather than only for a raise.

## Related

- [Coding sessions](coding-sessions.md#concept) — running, steering, resuming, and stopping.
- [Agent loop and tools](../developer/agent-loop-and-tools.md#concept) — the tool contract, registry, and policy port in detail.
- [Runtime operations](runtime.md#concept) — the M1 embedded runtime runbook.
- [Operator documentation index](README.md).
