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

Every tool resolves paths against the workspace root and refuses anything that
escapes it, whether by `..` traversal or through a symbolic link. The check is
against the *resolved* path, so a link pointing outside is refused even though
the name that reached the tool looked contained.

`bash` runs a real command on your machine, as you, with your filesystem
permissions. That is the honest statement of its reach: **it is not a sandbox.**
Loopex does not isolate a tool child from your machine in this milestone, and the
protection that exists is the host policy you name plus the workspace-root
containment above.

The child's environment is built from nothing rather than inherited. The launcher
is `/usr/bin/env -i`, and the only variable the child receives is a fixed `PATH`,
so no shell variable of yours — the provider credential included — reaches a tool
child by accident.

Every child runs in its own process group, and termination signals the group
rather than the leader, so a leader that spawned children and exited cannot leave
them running with nobody's name on them. Each job carries the run's committed
absolute deadline and runs under the earlier of that instant and the tool's own
declared wall-time budget; expiry enters the same cancellation sequence and the
owned process tree is confirmed cleaned before the run commits its bound.

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
loud what it is, once per session:

```text
loopex: the allow-all host policy is active. This is permissive local authority,
not a permission model: every tool call this session makes will be allowed.
```

It applies only where you name it. It is never a fallback, never a default, and
the shipped composition an embedder depends on refuses to start without a policy
precisely so that no embedder inherits this one.

Two permissive policies ship — one in `loopex_cli`, one in
`loopex_reference_client` — because a client application may not depend on
another client. That duplication is the honest consequence of the dependency
rule rather than an oversight.

<a id="operator-tools-artifacts"></a>
## Artifacts

A tool whose output exceeds its declared bound does not get truncated into the
conversation and does not silently lose the rest. The full bytes spill to an
artifact store under your state root, and the durable event carries the content
digest, media type, size, logical role, and an opaque retrieval reference.

The model sees a bounded result that names what was truncated. You retrieve the
whole output by that reference:

```text
loopex artifact 3f9c1a…  > full-output.txt
```

A reference to nothing says so rather than printing emptiness.

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

Select it with `--policy` by name for the two shipped policies, or start the
runtime yourself with `policy: YourModule` through `LoopexComposition.start/1`
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
rather than being forwarded to the operator.

### Artifact References

An artifact reference is a plain map with `digest`, `media_type`, `size`, `role`,
and `locator`. The locator is opaque: it is the retrieval handle and carries no
path an operator is expected to construct. Storage is content-addressed under
`<state root>/artifacts`, written to a temporary name and renamed into place, so
a partially written object is never readable under its final name.

`Loopex.Store.Local.Artifacts.fetch/2` verifies the digest on read. A round trip
is byte-exact, and a missing artifact reports unavailable rather than returning
empty content.

### Credential Boundary

The provider credential is read from `LOOPEX_PROVIDER_API_KEY` by the model
adapter and nowhere else. Every controlled tool child is launched through
`/usr/bin/env -i` with `PATH` as its only variable, so the credential-free child
environment is constructed rather than filtered — there is no inherited variable
for a filter to miss. The receipt records the child's environment variable names
and whether a provider credential was present, so the claim is journalled rather
than asserted. A provider error is bounded and has the credential's bytes
substituted out before any caller, report, or terminal can see it.

## Related

- [Coding sessions](coding-sessions.md#concept) — running, steering, resuming, and stopping.
- [Agent loop and tools](../developer/agent-loop-and-tools.md#concept) — the tool contract, registry, and policy port in detail.
- [Runtime operations](runtime.md#concept) — the M1 embedded runtime runbook.
- [Operator documentation index](README.md).
