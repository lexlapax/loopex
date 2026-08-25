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
- the resulting bytes exist on disk in a disposable repository created inside
  the task root.

**The host-policy refusal is not part of what this role proves.** The attended
run uses `--policy allow-all`, so no call is refused and none could be. The
refusal is demonstrated by the deterministic case
`a denied tool call inside a multi tool task is reported and the task continues
truthfully`, which names a refusing policy — a role `Da` case. Recording the
refusal among role `Db`'s claims would be exactly the substitution the next
paragraph forbids, and this record does not make it.

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

Observed on the development machine at this candidate: all four coding tools ran
-- `loopex.read`, `loopex.edit`, `loopex.write`, `loopex.bash` -- across five
real provider calls, the workspace ended carrying both the edited `notes.md` and
the created `summary.txt`, and the run ended `done`.

Three defects that only real execution exposed, each fixed at its source and
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

This is the argument for making the demonstration mandatory rather than
optional: 324 passing tests did not find any of the three, because the fixtures
bypassed exactly the layer that was broken.

## Related

- [Real-call attestations](M2-real-call-attestations.md) — the retained provider response identifiers a reviewer looks up.
- [Negative demonstrations](M2-negative-demonstrations.md) — eight safeguards disabled one at a time.
- [Toolchain matrix](M2-toolchain-matrix.md) — the three lanes the gate captures.
- [Evidence index](README.md).
