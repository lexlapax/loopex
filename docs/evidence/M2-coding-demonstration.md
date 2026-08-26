# M2 Coding Demonstration

The attended real-provider demonstration required for M2 closure. It is not an
outcome and not a feature; it is the evidence that the eleven outcomes add up to
a coding agent, and closure without it is refused.

This file is a record. What it can establish and what it cannot are stated
below, because the limit is the point: no check that runs offline can prove a
network call happened, and nothing here claims otherwise. The retained
identifiers either exist in the provider's account for the recorded window or
they do not, and only a person looking there can tell. That lookup is a closure
review step.

## What the demonstration is

Role `Db` of `apps/loopex_cli/test/coding_task_test.exs`, run with a provider
credential through the standalone selector channel. The claim it carries:

- a real provider drove the shipped `loopex` command through several turns;
- several distinct tools ran, including one `edit` and one `bash`;
- the reply was reconstructed once per turn;
- one tool call was refused by the host policy, the transcript reported the
  refusal, and the task continued past it truthfully;
- the resulting bytes exist on disk in a disposable repository created inside
  the task root.

**The host-policy refusal is part of what this role proves, and is taken in the
attended run.** The run is invoked as `--policy shell-allowlist`, a stance that
permits a named list of shell commands and refuses the rest. The task's fourth
step runs `cat`, which the stance permits and which executes as a real effect;
its fifth step runs `rm summary.txt`, which the stance refuses. Three separate
things are then asserted: that the refusal reached the transcript, that
`summary.txt` still exists so the refused command took no effect, and that the
run reached its own ending *after* the refusal rather than dying on it.

This replaces an earlier arrangement in which the attended run used
`--policy allow-all` — under which no call could be refused — and the refusal
was credited to the deterministic role `Da` case
`a denied tool call inside a multi tool task is reported and the task continues
truthfully`. That was a substitution of a deterministic case for a real one,
which the paragraph below forbids, and it is no longer made. The `Da` case
remains as supporting coverage.

`shell-allowlist` is a **scope** stance and not a sandbox: it matches the
leading word of a command, and a compound command reaches past it. That limit is
stated in the policy's own documentation and printed in the transcript of every
run under it. What the demonstration needs from it is a genuine host decision
that permits some work and refuses other work, which it is.

**The answer streams.** Every committed reply of the attended run declares
`streamed: true` with a positive delta count, and the case asserts that on the
run's own durable records rather than on a delta the test process happened to
catch. The adapter emits each chunk as the provider sends it and accumulates the
same chunks into the reply, so the reply replays its own deltas byte for byte.

The five deterministic cases in role `Da` support that claim. They run the real
coding tools, the real executor, and the real store against a disposable Git
repository with only the model scripted. **They never substitute for the real
cases.** A green `Da` with an unavailable `Db` is evidence unavailable, never a
pass.

## What the run seals

The attended run seals its identity through the bound selector runner, and that
sealed identity is what the other two records must match:

| Record | Carries |
| --- | --- |
| [Toolchain matrix](M2-toolchain-matrix.md) | One capture row per lane, each naming the demonstration role's sealed provider, model, endpoint, adapter build, executor build, executor identity, and tool identity |
| [Real-call attestations](M2-real-call-attestations.md) | Every provider response identifier the role observed, and the provider's reported token totals across exactly those responses. A streamed call carries the provider's per-call `request-id`, which is the identifier its account surfaces |

All three real-provider roles must agree on provider, model, endpoint, and
adapter build. The demonstration role seals the executor and the tools beside
them, because its claim is about a coding task and not about a model call, and
its tool identity names every generation the run could reach rather than the
subset a particular model chose.

## What the run does

The attended task is sequential by construction. Its steps depend on each
other -- the line to edit is the line the read returned -- so the turns are real
rather than requested. A task whose steps are independent is one a model can and
should batch into a single turn, and a single batched turn demonstrates a tool
set rather than a loop.

Each run reports what it observed on the diagnostic stream, beside its
attestation identifiers, in the form

```text
loopex demonstration observed: tools=<comma-separated tool ids> files=<comma-separated> ending=<done|not-done>
```

so a reviewer reads what the run did rather than inferring it from a pass. The
gate's selector runner suppresses the test formatter, and without this a failed
assertion reaches an operator as "the selector failed" and nothing else.

Observed at the closure candidate: all four coding tools ran —
`loopex.read`, `loopex.edit`, `loopex.write`, `loopex.bash` — across seven real
provider calls, every committed reply declared it streamed with a positive delta
count, one `loopex.bash` call was refused by the host stance and reported, the
run continued past the refusal and ended `done`, and the workspace ended
carrying both the edited `notes.md` and the `summary.txt` the refused command
did not remove.

Seven is this task's own count. The role that carries this run in the
[real-call attestations](M2-real-call-attestations.md) records eight, because
that role is two cases: this task and a single attestation call beside it. The
two numbers describe different things and neither corrects the other.

The lane rows in the [toolchain matrix](M2-toolchain-matrix.md) name which
lanes captured this role and what each of them observed; this paragraph
describes the run, not the lane coverage.

Four defects that only real execution exposed, each fixed at its source and
each covered by a locked case afterwards:

1. The model adapter sent only the most recent user message rather than the
   committed conversation. Every test passed, because fixtures read
   `request.messages` directly, while the real path had the model seeing its
   original instruction again on every turn and calling the same tool until the
   run hit its turn bound.
2. The public tool events carried the tool call's identifier but not the tool's
   generation, so a terminal reading the public plane rendered an empty name
   beside an opaque identifier.
3. The interrupt handler never installed, because `os:set_signal/2` refuses
   `sigint` outright and the failure happened inside a spawned process where
   nothing observed it.
4. `--policy` accepted exactly one name and that name permitted everything, so
   the outcome's own claim — that a run under a refusing policy reports the
   refusal and continues truthfully — was unreachable from the shipped command.
   The deterministic case proved it with a fixture policy an operator has no way
   to select.

This is the argument for making the demonstration mandatory rather than
optional: a full green suite found none of them, because the fixtures bypassed
exactly the layer that was broken — and the fourth was not a broken layer at all
but a missing one that no offline case could miss, since every offline case
supplied the policy directly.

## Related

- [Real-call attestations](M2-real-call-attestations.md) — the retained provider response identifiers a reviewer looks up.
- [Negative demonstrations](M2-negative-demonstrations.md) — eight safeguards disabled one at a time.
- [Toolchain matrix](M2-toolchain-matrix.md) — the three lanes the gate captures.
- [Evidence index](README.md).
