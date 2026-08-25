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
- the answer streamed and reconstructed once per turn;
- one host-policy refusal was reported and the task continued truthfully;
- the resulting bytes exist on disk in a disposable repository created inside
  the task root.

The five deterministic cases in role `Da` support that claim. They run the real
coding tools, the real executor, and the real store against a disposable Git
repository with only the model scripted. **They never substitute for the real
cases.** A green `Da` with an unavailable `Db` is evidence unavailable, never a
pass.

## Capture record

<!-- loopex:m2-demonstration:start -->
```text
demonstration candidate=<40 lowercase hex> gate_sha256=<64 lowercase hex> command=bash:scripts/check-m2-gate.sh role=Db selector=apps/loopex_cli/test/coding_task_test.exs turns=<positive integer> tools=<comma-separated tool ids> refusals=<non-negative integer> workspace=<task-root-relative path> verdict=<GREEN|RED> exit=<integer> provider=<lowercase provider> model=<printable> endpoint=<printable> adapter_build=<printable> executor_build=<printable> executor_identity=<printable> recorded=<RFC3339 UTC>
```
<!-- loopex:m2-demonstration:end -->

The capture row is populated by the attended gate run that produces the closure
candidate. It is empty here because that run has not been performed: this
revision is the implementation candidate, not the closure candidate, and a row
written before the run it describes would be a claim about a run that did not
happen.

The identity fields this record seals are the ones
[the real-call attestations](M2-real-call-attestations.md) must match byte for
byte, and all three real-provider roles must agree on `provider`, `model`,
`endpoint`, and `adapter_build`.

## Observed development-time behaviour

Recorded here as development evidence, not as the attended capture. It is what
the implementation candidate did on a developer machine, outside the gate
runner, and it is retained because it is what a reviewer would otherwise have to
take on prose.

| Observation | Value |
| --- | --- |
| Provider identity | `anthropic` / `claude-haiku-4-5-20251001` / `https://api.anthropic.com` |
| Adapter build | `loopex_llm_reqllm@0.0.0` |
| Turns completed by the multi-tool task | 4 |
| Tools the model chose | `loopex.edit`, `loopex.write`, `loopex.bash` |
| Bytes on disk after the task | `notes.md` edited in place, `summary.txt` created |

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
